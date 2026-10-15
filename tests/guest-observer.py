#!/usr/bin/env python3
"""External observer; raw system samples stay private and are never uploaded."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def process_identity(pid):
    try:
        env = os.environ.copy()
        env['LC_ALL'] = 'C'
        value = subprocess.check_output(['ps', '-p', str(pid), '-o', 'pgid=,lstart='],
                                        text=True, timeout=1, env=env)
        return ' '.join(value.split()) or None
    except (OSError, subprocess.SubprocessError): return None


def sample_frames(raw):
    frames = []
    for line in raw.read_text(errors='replace').splitlines():
        # Keep call-stack lines, discard all headers and binary/path sections.
        m = re.match(r'\s*[+!:| ]*\d+ ([a-zA-Z_][a-zA-Z0-9_:$<>~.* ()+,-]*?)\s+\(in ([a-zA-Z0-9_.-]+)\)(.*)', line)
        if m: frames.append(dict(function=m[1], image=m[2]))
        elif re.match(r'\s*\d+ Thread_\d+', line):
            frames.append(dict(thread=re.search(r'Thread_\d+', line)[0]))
    return frames


def host_processes(pgid):
    # Query only this supervised group. Do not fall back to a whole-host ps.
    fields = 'pid=,ppid=,pgid=,stat=,lstart=,'
    if sys.platform == 'darwin':
        command = ['/bin/ps', '-g', str(pgid), '-o', fields + 'ucomm=']
    elif sys.platform.startswith('linux'):
        # procps parses a trailing negative number as a process-group selector.
        command = ['/bin/ps', '-o', fields + 'comm=', '-' + str(pgid)]
    else:
        raise RuntimeError('group-query-platform-unavailable')
    env = os.environ.copy()
    env['LC_ALL'] = 'C'
    table = subprocess.run(command, capture_output=True, text=True, timeout=2, env=env)
    if table.returncode != 0:
        raise RuntimeError('group-process-query-failed')
    rows, non_nodes, skipped = [], 0, []
    for line in table.stdout.splitlines():
        # lstart has five fields in the C locale; comm stays in memory only.
        parts = line.split(None, 9)
        if len(parts) != 10 or not all(part.isdigit() for part in parts[:3]):
            raise RuntimeError('invalid-process-row')
        if int(parts[2]) != pgid:
            skipped.append(dict(pid=int(parts[0]), reason='left-supervised-group'))
            continue
        is_node = Path(parts[9]).name.lower() in ('node', 'nodejs')
        if not is_node: non_nodes += 1
        if not re.fullmatch(r'[A-Za-z+<>Nls0-9-]+', parts[3]):
            raise RuntimeError('invalid-process-state')
        rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]), pgid=pgid, state=parts[3],
                         start_identity=' '.join([parts[2], *parts[4:9]]), is_node=is_node))
    return rows, non_nodes, skipped


def observe_host_process(row, private, deadline):
    result = dict(row, descriptor_status='not-collected', sample_status='not-collected')
    result.pop('is_node', None)
    def same_process():
        return process_identity(row['pid']) == row['start_identity']
    def remaining(limit):
        value = deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError('observation-budget-exhausted')
        return min(limit, value)
    def skip_changed():
        result.pop('descriptors', None)
        result.pop('sample_frames', None)
        result['identity_status'] = 'changed-or-unavailable'
        result['descriptor_status'] = 'skipped-identity-unconfirmed'
        result['sample_status'] = 'skipped-identity-unconfirmed'
        return result
    try:
        remaining(1)
        if not same_process(): return skip_changed()
        result['identity_status'] = 'matched'
        try:
            fds = subprocess.run(['lsof', '-nP', '-p', str(row['pid']), '-F', 'pfta'],
                                 capture_output=True, text=True, timeout=remaining(2))
            pattern = r'(?:p\d+|f(?:\d+|cwd|txt|rtd)|a[rwu ]|t[A-Za-z0-9]+)'
            result['descriptors'] = [line for line in fds.stdout.splitlines() if re.fullmatch(pattern, line)]
            result['descriptor_exit_status'] = fds.returncode
            result['descriptor_status'] = 'completed' if fds.returncode == 0 else 'failed'
        except FileNotFoundError:
            result['descriptor_status'] = 'tool-unavailable'
        except PermissionError:
            result['descriptor_status'] = 'permission-denied'
        except subprocess.TimeoutExpired:
            result['descriptor_status'] = 'timed-out'
        except OSError:
            result['descriptor_status'] = 'os-error'
        if not same_process(): return skip_changed()
        remaining(1)
        if sys.platform != 'darwin':
            result['sample_status'] = 'macOS-only'
            return result
        raw, errors = Path(private) / f"{row['pid']}.sample", Path(private) / f"{row['pid']}.errors"
        try:
            # sample includes every thread. Its raw output never leaves 0700 storage.
            with errors.open('wb') as error_file:
                sample = subprocess.run(['/usr/bin/sample', str(row['pid']), '1', '10', '-mayDie', '-file', str(raw)],
                                        stdout=error_file, stderr=subprocess.STDOUT, timeout=remaining(3))
            result['sample_exit_status'] = sample.returncode
            error_text = errors.read_text(errors='replace')
            denied = re.search(r'permission|not permitted|access denied|unable to attach|cannot attach|task_for_pid|must be root',
                               error_text, re.IGNORECASE)
            if denied:
                result['sample_status'] = 'permission-denied'
            elif sample.returncode != 0:
                result['sample_status'] = 'failed'
            else:
                result['sample_frames'] = sample_frames(raw)
                result['sample_status'] = 'completed' if any('function' in frame for frame in result['sample_frames']) else 'no-sanitized-frames'
        except FileNotFoundError:
            result['sample_status'] = 'tool-or-output-unavailable'
        except PermissionError:
            result['sample_status'] = 'permission-denied'
        except subprocess.TimeoutExpired:
            result['sample_status'] = 'timed-out'
        except OSError:
            result['sample_status'] = 'os-error'
        if not same_process(): return skip_changed()
    except TimeoutError:
        if result['descriptor_status'] == 'not-collected': result['descriptor_status'] = 'skipped-budget-exhausted'
        if result['sample_status'] == 'not-collected': result['sample_status'] = 'skipped-budget-exhausted'
    return result


def host_events(a, result):
    # Fixed producer vocabulary only; never copy arbitrary trace keys or text.
    common = {'file:bootstrap', 'file:registered', 'body:start', 'body:done', 'body:error', 'after:last'}
    stages = {
        'job-ledger-test': {'fixture:ledger.ready', 'fixture:ledger.flush', 'fixture:rm',
                            'plugin:rm', 'progress:ledger.flush', 'progress:rm'},
        'job-tracking-runtime-test': {'fixture:ledger.ready', 'fixture:jobs.disposeAll', 'fixture:ledger.flush',
                                     'fixture:rm', 'bridge:server.listen', 'bridge:server.close',
                                     'registration:server.listen', 'registration:jobs.disposeAll',
                                     'registration:ledger.flush', 'registration:ctx.dispose',
                                     'registration:server.close', 'registration:rm'},
        'development-tools-test': {'fixture:server.listen', 'fixture:server.close', 'fixture:rm',
                                   'cli:close', 'cli:finally.close', 'cli:preflight-or-invalid.close',
                                   'proxy:server.listen', 'proxy:server.close'},
    }
    allowed = {tag: common | {stage + ':' + event for stage in values for event in ('start', 'done', 'error')}
               for tag, values in stages.items()}
    allowed['job-tracking-runtime-test'] |= {'import:' + module + ':' + event
        for module in ('cordis', 'jobs-local', 'system-prompt', 'tools', 'tool-bash', 'tool-jobs')
        for event in ('start', 'done')}
    allowed['runner'] = {'bootstrap', 'beforeExit', 'exit'}
    allowed['shell'] = {stage + ':' + event for stage in ('prepare', 'syntax', 'suite') for event in ('start', 'done')}
    result['service_events'] = []
    try:
        with a.events.open('rb') as source:
            size = source.seek(0, os.SEEK_END)
            offset = max(0, size - 1024 * 1024)
            source.seek(offset)
            if offset: source.readline()  # Discard a partial leading JSON line.
            lines = source.read(1024 * 1024).decode('utf-8', errors='replace').splitlines()
        result['service_events_status'] = 'truncated' if offset else 'completed'
        for line in lines:
            try: row = json.loads(line)
            except ValueError: continue
            if not isinstance(row, dict) or row.get('schema') != 1 or row.get('phase') != 'job-tracking' or a.phase != 'job-tracking':
                continue
            tag, event = row.get('fileTag'), row.get('event')
            if not isinstance(tag, str) or not isinstance(event, str) or event not in allowed.get(tag, set()):
                continue
            if type(row.get('pid')) is not int or not 0 < row['pid'] < 2 ** 31:
                continue
            clean = dict(schema=1, phase='job-tracking', fileTag=tag, event=event, pid=row['pid'])
            for field in ('ppid', 'case_id', 'exit_code'):
                value = row.get(field)
                if type(value) is int and 0 <= value < 2 ** 31: clean[field] = value
            value = row.get('monotonic_ns')
            if isinstance(value, str) and re.fullmatch(r'[0-9]{1,30}', value): clean['monotonic_ns'] = value
            value = row.get('node_version')
            if isinstance(value, str) and re.fullmatch(r'v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}', value): clean['node_version'] = value
            result['service_events'].append(clean)
    except OSError as error:
        result['service_events_status'] = 'unavailable'
        result['service_events_error'] = type(error).__name__


def collect_host(a, result, identity, save):
    deadline = time.monotonic() + 8
    result.update(mode='host-only', process_tree_status='not-collected', sample_budget_seconds=8)
    host_events(a, result)
    # The runner created a new session whose leader PID is also its original PGID.
    if not identity or identity == 'unknown' or identity.split()[0] != str(a.pid) or process_identity(a.pid) != identity:
        result['process_tree_status'] = 'skipped-leader-identity-unconfirmed'
        result['sample_status'] = 'skipped-leader-identity-unconfirmed'
        return
    try:
        rows, non_nodes, skipped = host_processes(a.pid)
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
        result['process_tree_status'] = 'failed'
        result['process_tree_error'] = type(error).__name__
        if isinstance(error, RuntimeError): result['process_tree_reason'] = str(error)
        result['sample_status'] = 'skipped-process-tree-unavailable'
        return
    if process_identity(a.pid) != identity or not any(row['pid'] == a.pid and row['start_identity'] == identity for row in rows):
        result['process_tree_status'] = 'skipped-leader-identity-changed'
        result['sample_status'] = 'skipped-leader-identity-changed'
        return
    candidates = [row for row in rows if row['is_node']]
    tree = [{key: value for key, value in row.items() if key != 'is_node'} for row in rows]
    result.update(process_tree_status='completed', process_tree=tree,
                  non_node_processes_skipped=non_nodes, skipped_processes=skipped, host_processes=[])
    save()
    with tempfile.TemporaryDirectory(prefix='dsh-private-host-sample-') as private:
        os.chmod(private, 0o700)
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = {pool.submit(observe_host_process, row, private, deadline): row for row in candidates}
            for future in as_completed(futures):
                try: observation = future.result()
                except Exception as error:
                    observation = {key: value for key, value in futures[future].items() if key != 'is_node'}
                    observation.update(descriptor_status='observer-error', sample_status='observer-error',
                                       observer_error=type(error).__name__)
                result['host_processes'].append(observation)
                save()
    result['host_processes'].sort(key=lambda row: row['pid'])
    result['sample_status'] = ('macOS-only' if sys.platform != 'darwin' else 'observations-recorded') if candidates else 'no-node-processes'


def collect(a):
    a.output.mkdir(parents=True, exist_ok=True)
    result = dict(host_pid=a.pid, phase=a.phase)
    identity = a.start_identity if getattr(a, 'host_only', False) else a.start_identity or process_identity(a.pid)
    result['host_start_identity'] = identity
    def same_process():
        return identity is not None and identity != 'unknown' and process_identity(a.pid) == identity
    def save():
        (a.output / 'observer.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
    if getattr(a, 'host_only', False):
        collect_host(a, result, identity, save)
        save()
        return
    commands = [('process-tree', ['ps', '-axo', 'pid=,ppid=,pgid=,stat=']),
                ('host-fds', ['lsof', '-nP', '-p', str(a.pid), '-F', 'pfta'])]
    for label, command in commands:
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=2)
            # Fields only: numeric process identity or lsof descriptor/access/type.
            lines = completed.stdout.splitlines()
            pattern = r'\s*\d+\s+\d+\s+\d+\s+[A-Za-z+<>Nls0-9-]+' if label == 'process-tree' else r'(?:p\d+|f(?:\d+|cwd|txt|rtd)|a[rwu ]|t[A-Za-z0-9]+)'
            result[label] = [s.strip() for s in lines if re.fullmatch(pattern, s.strip())]
            result[label + '-status'] = completed.returncode
        except (OSError, subprocess.TimeoutExpired) as e:
            result[label + '-error'] = type(e).__name__
    try:
        result['service_events'] = [json.loads(s) for s in a.events.read_text().splitlines()
                                    if json.loads(s).get('phase') == a.phase]
    except (OSError, ValueError): result['service_events'] = []
    save()
    if sys.platform == 'darwin' and same_process():
        # TemporaryDirectory has mode 0700. No raw args, paths, environment,
        # registers or memory contents are copied to the artifact directory.
        with tempfile.TemporaryDirectory(prefix='dsh-private-sample-') as private:
            raw = Path(private) / 'sample.txt'
            try:
                sample = subprocess.run(['/usr/bin/sample', str(a.pid), '2', '10', '-mayDie', '-file', str(raw)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
                result['sample_exit_status'] = sample.returncode
                result['sample_frames'] = sample_frames(raw)
            except (OSError, subprocess.TimeoutExpired) as e:
                result['sample_error'] = type(e).__name__
            save()
            env = os.environ.copy()
            env['DSH_LLDB_SNAPSHOT'] = str(a.output / 'guest-state.json')
            plugin = Path(__file__).with_name('guest_snapshot.py').resolve()
            try:
                if not same_process():
                    result['lldb_error'] = 'original-process-ended-before-attach'
                    save()
                    return
                lldb = subprocess.run(['xcrun', 'lldb', '--batch', '-p', str(a.pid),
                    '-o', 'command script import "' + str(plugin) + '"',
                    '-o', 'dsh-guest-snapshot'],
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
                result['lldb_exit_status'] = lldb.returncode
            except (OSError, subprocess.TimeoutExpired) as e:
                result['lldb_error'] = type(e).__name__
    else:
        result['sample_error'] = 'macOS-only; no fabricated sample'
    save()


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--phase', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--events', type=Path, required=True)
    p.add_argument('--executable', required=True)
    p.add_argument('--start-identity')
    p.add_argument('--host-only', action='store_true')
    collect(p.parse_args())
