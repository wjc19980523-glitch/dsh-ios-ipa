#!/usr/bin/env python3
"""External observer; raw system samples stay private and are never uploaded."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


class ObservationBudgetExhausted(TimeoutError):
    pass


def run_tool(tool, purpose, command, *, observations, limit, deadline=None, pid=None, **kwargs):
    """Record bounded, numeric tool evidence without arguments or tool output."""
    start = time.monotonic()
    remaining = None if deadline is None else max(0, deadline - start)
    allocated = limit if remaining is None else min(limit, remaining)
    entry = dict(tool=tool, purpose=purpose, limit_seconds=limit,
                 remaining_seconds=remaining, allocated_timeout_seconds=allocated,
                 monotonic_start_seconds=start, status='running')
    if pid is not None: entry['pid'] = pid
    # Both observation modes have a small fixed call graph. Bound retained
    # entries as well if a caller accidentally repeats identity queries.
    if len(observations) < 64: observations.append(entry)
    try:
        if allocated <= 0:
            entry['status'] = 'budget-exhausted'
            raise ObservationBudgetExhausted('observation-budget-exhausted')
        completed = subprocess.run(command, timeout=allocated, **kwargs)
        entry['return_code'] = completed.returncode
        entry['status'] = 'completed' if completed.returncode == 0 else 'nonzero-exit'
        return completed
    except ObservationBudgetExhausted:
        raise
    except subprocess.TimeoutExpired:
        entry['status'] = 'timed-out'
        raise
    except FileNotFoundError as error:
        entry['status'] = 'tool-unavailable'
        if type(error.errno) is int: entry['errno'] = error.errno
        raise
    except PermissionError as error:
        entry['status'] = 'permission-denied'
        if type(error.errno) is int: entry['errno'] = error.errno
        raise
    except OSError as error:
        entry['status'] = 'os-error'
        if type(error.errno) is int: entry['errno'] = error.errno
        raise
    except Exception:
        entry['status'] = 'observer-error'
        raise
    finally:
        end = time.monotonic()
        entry['monotonic_end_seconds'] = end
        entry['elapsed_seconds'] = max(0, end - start)


def process_identity(pid, observations=None, deadline=None, purpose='identity-check'):
    try:
        env = os.environ.copy()
        env['LC_ALL'] = 'C'
        query = run_tool('ps-identity', purpose, ['ps', '-p', str(pid), '-o', 'pgid=,lstart='],
                         observations=observations if observations is not None else [],
                         limit=1, deadline=deadline, pid=pid, capture_output=True, text=True, env=env)
        if query.returncode != 0: return None
        return ' '.join(query.stdout.split()) or None
    except ObservationBudgetExhausted: raise
    except (OSError, subprocess.SubprocessError): return None


def parse_sample_frames(text):
    frames = []
    for line in text.splitlines():
        # Keep call-stack lines, discard all headers and binary/path sections.
        m = re.match(r'\s*[+!:| ]*\d+ ([a-zA-Z_][a-zA-Z0-9_:$<>~.* ()+,-]*?)\s+\(in ([a-zA-Z0-9_.-]+)\)(.*)', line)
        if m: frames.append(dict(function=m[1], image=m[2]))
        elif re.match(r'\s*\d+ Thread_\d+', line):
            frames.append(dict(thread=re.search(r'Thread_\d+', line)[0]))
    return frames


def sample_frames(raw):
    return parse_sample_frames(raw.read_text(errors='replace'))


def timeout_file_evidence(path, kind, deadline):
    """Only bounded counts/hints after the timed-out direct tool has returned."""
    result = dict(status='budget-exhausted')
    if time.monotonic() >= deadline: return result
    limit = 64 * 1024
    try:
        if path.is_symlink(): return dict(status='non-regular')
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        with os.fdopen(os.open(path, flags), 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode): return dict(status='non-regular')
            result['source_bytes'] = info.st_size
            if time.monotonic() >= deadline: return result
            data = stream.read(limit + 1)
        result['read_bytes'] = len(data)
        if time.monotonic() >= deadline: return result
        if len(data) > limit:
            result['status'] = 'byte-limit'
            return result
        text = data.decode('utf-8', errors='replace')
        if time.monotonic() >= deadline: return result
        if kind == 'report':
            frames = parse_sample_frames(text)
            parsed = dict(frame_count=len(frames), function_frame_count=sum('function' in frame for frame in frames))
        else:
            parsed = dict(permission_hint=bool(re.search(
                r'permission|not permitted|access denied|unable to attach|cannot attach|task_for_pid|must be root',
                text, re.IGNORECASE)))
        if time.monotonic() >= deadline: return result
        result.update(status='observed', **parsed)
    except FileNotFoundError: result['status'] = 'missing'
    except OSError as error: result.update(status='read-error', errno=error.errno)
    return result


def host_processes(pgid, observations=None, deadline=None):
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
    table = run_tool('ps-group', 'supervised-group', command,
                     observations=observations if observations is not None else [],
                     limit=2, deadline=deadline, pid=pgid, capture_output=True, text=True, env=env)
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
        # Darwin's ucomm column is width-padded even in the final position.
        is_node = Path(parts[9].strip()).name.lower() in ('node', 'nodejs')
        if not is_node: non_nodes += 1
        if not re.fullmatch(r'[A-Za-z+<>Nls0-9-]+', parts[3]):
            raise RuntimeError('invalid-process-state')
        rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]), pgid=pgid, state=parts[3],
                         start_identity=' '.join([parts[2], *parts[4:9]]), is_node=is_node))
    return rows, non_nodes, skipped


def observe_host_process(row, private, deadline, sample_policy='may-exit'):
    if sample_policy not in ('may-exit', 'owned-stable-fixture'):
        raise ValueError('invalid-host-sample-policy')
    result = dict(row, descriptor_status='not-collected', sample_status='not-collected',
                  sample_policy=sample_policy, tool_observations=[])
    result.pop('is_node', None)
    def same_process():
        return process_identity(row['pid'], result['tool_observations'], deadline) == row['start_identity']
    def remaining(limit):
        value = deadline - time.monotonic()
        if value <= 0:
            raise ObservationBudgetExhausted('observation-budget-exhausted')
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
            fds = run_tool('lsof', 'host-descriptors', ['lsof', '-nP', '-p', str(row['pid']), '-F', 'pfta'],
                           observations=result['tool_observations'], limit=2, deadline=deadline,
                           pid=row['pid'], capture_output=True, text=True)
            pattern = r'(?:p\d+|f(?:\d+|cwd|txt|rtd)|a[rwu ]|t[A-Za-z0-9]+)'
            result['descriptors'] = [line for line in fds.stdout.splitlines() if re.fullmatch(pattern, line)]
            result['descriptor_exit_status'] = fds.returncode
            result['descriptor_status'] = 'completed' if fds.returncode == 0 else 'failed'
        except ObservationBudgetExhausted:
            raise
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
            command = ['/usr/bin/sample', str(row['pid']), '1', '10']
            # The stable test fixture stays alive until collect returns; symbol
            # lookup can occur after sampling. Transient targets keep -mayDie.
            if sample_policy == 'may-exit': command.append('-mayDie')
            command += ['-file', str(raw)]
            with errors.open('wb') as error_file:
                sample = run_tool('sample', 'host-all-threads',
                                  command,
                                  observations=result['tool_observations'], limit=3, deadline=deadline,
                                  pid=row['pid'], stdout=error_file, stderr=subprocess.STDOUT)
            result['sample_exit_status'] = sample.returncode
            error_text = errors.read_text(errors='replace')
            denied = re.search(r'permission|not permitted|access denied|unable to attach|cannot attach|task_for_pid|must be root',
                               error_text, re.IGNORECASE)
            if denied:
                result['sample_status'] = 'permission-denied'
                if result['tool_observations'][-1]['tool'] == 'sample':
                    result['tool_observations'][-1]['status'] = 'permission-denied'
            elif sample.returncode != 0:
                result['sample_status'] = 'failed'
            else:
                result['sample_frames'] = sample_frames(raw)
                result['sample_status'] = 'completed' if any('function' in frame for frame in result['sample_frames']) else 'no-sanitized-frames'
        except ObservationBudgetExhausted:
            raise
        except FileNotFoundError:
            result['sample_status'] = 'tool-or-output-unavailable'
        except PermissionError:
            result['sample_status'] = 'permission-denied'
        except subprocess.TimeoutExpired:
            result['sample_status'] = 'timed-out'
            # run() has returned after stopping/waiting for its direct child.
            # Partial output is evidence only; no exit code or success is inferred.
            result['sample_timeout_evidence'] = dict(
                report=timeout_file_evidence(raw, 'report', deadline),
                errors=timeout_file_evidence(errors, 'errors', deadline))
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
                                     'fixture:rm', 'fixture:children.stop', 'bridge:server.listen', 'bridge:server.close',
                                     'bridge:ctx.dispose', 'bridge:ledger.flush', 'bridge:env.restore',
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
    issues, files = set(), [(a.events, None)]
    max_files, max_bytes, per_file_bytes = 32, 1024 * 1024, 256 * 1024
    shard_name = re.compile(re.escape(a.events.name) + r'\.([1-9][0-9]{0,9})\.jsonl')
    # Bound discovery as well as reads; no paths or directory names are saved.
    try:
        with os.scandir(a.events.parent) as entries:
            for count, entry in enumerate(entries):
                if count >= 256:
                    issues.add('directory-entry-limit')
                    break
                match = shard_name.fullmatch(entry.name)
                if not match or int(match[1]) >= 2 ** 31: continue
                if len(files) >= max_files:
                    issues.add('file-count-limit')
                    break
                files.append((Path(entry.path), int(match[1])))
    except OSError:
        issues.add('directory-unavailable')
    files[1:] = sorted(files[1:], key=lambda item: item[1])
    result['service_events_files'] = []
    result['service_events_bytes_read'] = 0
    for path, shard_pid in files:
        summary = dict(kind='main' if shard_pid is None else 'pid-shard', status='completed')
        if shard_pid is not None: summary['pid'] = shard_pid
        result['service_events_files'].append(summary)
        allowance = min(per_file_bytes, max_bytes - result['service_events_bytes_read'])
        if allowance <= 0:
            issues.add('byte-limit')
            summary['status'] = 'skipped-byte-limit'
            continue
        try:
            if path.is_symlink() or not path.is_file():
                if not path.exists(): raise FileNotFoundError()
                issues.add('non-regular-file')
                summary['status'] = 'non-regular-file'
                continue
            with path.open('rb') as source:
                size = source.seek(0, os.SEEK_END)
                offset = max(0, size - allowance)
                source.seek(offset)
                data = source.read(allowance)
            result['service_events_bytes_read'] += len(data)
        except FileNotFoundError:
            issues.add('main-file-missing' if shard_pid is None else 'shard-file-missing')
            summary['status'] = 'missing'
            continue
        except OSError:
            issues.add('file-unavailable')
            summary['status'] = 'unavailable'
            continue
        if offset:
            issues.add('byte-limit')
            summary['status'] = 'incomplete'
            data = data.partition(b'\n')[2]  # Discard the partial leading line.
        if data and not data.endswith(b'\n'):
            issues.add('partial-line')
            summary['status'] = 'incomplete'
        if not data and shard_pid is not None:
            issues.add('empty-shard-file')
            summary['status'] = 'incomplete'
        try: lines = data.decode('utf-8').splitlines()
        except UnicodeDecodeError:
            issues.add('invalid-utf8')
            summary['status'] = 'incomplete'
            lines = data.decode('utf-8', errors='replace').splitlines()
        for line in lines:
            try: row = json.loads(line)
            except ValueError:
                issues.add('malformed-json')
                summary['status'] = 'incomplete'
                continue
            if not isinstance(row, dict) or type(row.get('schema')) is not int or row['schema'] != 1 or row.get('phase') != 'job-tracking' or a.phase != 'job-tracking':
                issues.add('invalid-record')
                summary['status'] = 'incomplete'
                continue
            tag, event = row.get('fileTag'), row.get('event')
            if not isinstance(tag, str) or not isinstance(event, str) or event not in allowed.get(tag, set()):
                issues.add('invalid-record')
                summary['status'] = 'incomplete'
                continue
            if type(row.get('pid')) is not int or not 0 < row['pid'] < 2 ** 31:
                issues.add('invalid-record')
                summary['status'] = 'incomplete'
                continue
            if shard_pid is not None and row['pid'] != shard_pid:
                issues.add('shard-pid-mismatch')
                summary['status'] = 'incomplete'
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
    if not result['service_events']: issues.add('no-valid-events')
    result['service_events_issues'] = sorted(issues)
    available = any(item['status'] in ('completed', 'incomplete') for item in result['service_events_files'])
    result['service_events_status'] = ('incomplete' if available else 'unavailable') if issues else 'completed'


def collect_host(a, result, identity, save):
    start = time.monotonic()
    deadline = start + 8
    sample_policy = getattr(a, 'host_sample_policy', 'may-exit')
    if sample_policy not in ('may-exit', 'owned-stable-fixture'):
        raise ValueError('invalid-host-sample-policy')
    result.update(mode='host-only', process_tree_status='not-collected', sample_budget_seconds=8,
                  sample_policy=sample_policy,
                  observation_started_monotonic_seconds=start,
                  observation_deadline_monotonic_seconds=deadline)
    host_events(a, result)
    # The runner created a new session whose leader PID is also its original PGID.
    try:
        confirmed = (identity and identity != 'unknown' and identity.split()[0] == str(a.pid)
                     and process_identity(a.pid, result['tool_observations'], deadline, 'leader-before-tree') == identity)
    except TimeoutError:
        result['process_tree_status'] = 'skipped-budget-exhausted'
        result['sample_status'] = 'skipped-budget-exhausted'
        return
    if not confirmed:
        result['process_tree_status'] = 'skipped-leader-identity-unconfirmed'
        result['sample_status'] = 'skipped-leader-identity-unconfirmed'
        return
    try:
        rows, non_nodes, skipped = host_processes(a.pid, result['tool_observations'], deadline)
    except ObservationBudgetExhausted:
        result['process_tree_status'] = 'skipped-budget-exhausted'
        result['sample_status'] = 'skipped-budget-exhausted'
        return
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
        result['process_tree_status'] = 'failed'
        result['process_tree_error'] = type(error).__name__
        if isinstance(error, RuntimeError): result['process_tree_reason'] = str(error)
        result['sample_status'] = 'skipped-process-tree-unavailable'
        return
    try:
        confirmed = process_identity(a.pid, result['tool_observations'], deadline, 'leader-after-tree') == identity
    except TimeoutError:
        result['process_tree_status'] = 'skipped-budget-exhausted'
        result['sample_status'] = 'skipped-budget-exhausted'
        return
    if not confirmed or not any(row['pid'] == a.pid and row['start_identity'] == identity for row in rows):
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
            futures = {(pool.submit(observe_host_process, row, private, deadline) if sample_policy == 'may-exit'
                        else pool.submit(observe_host_process, row, private, deadline, sample_policy)): row for row in candidates}
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
    start = time.monotonic()
    result = dict(host_pid=a.pid, phase=a.phase, tool_observations=[],
                  observation_started_monotonic_seconds=start,
                  observation_deadline_monotonic_seconds=None)
    identity = a.start_identity if getattr(a, 'host_only', False) else a.start_identity or process_identity(
        a.pid, result['tool_observations'], purpose='initial-identity')
    result['host_start_identity'] = identity
    def same_process():
        return identity is not None and identity != 'unknown' and process_identity(
            a.pid, result['tool_observations']) == identity
    def save():
        (a.output / 'observer.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
    if getattr(a, 'host_only', False):
        try:
            collect_host(a, result, identity, save)
        finally:
            end = time.monotonic()
            result['observation_ended_monotonic_seconds'] = end
            result['observation_elapsed_seconds'] = max(0, end - result['observation_started_monotonic_seconds'])
            save()
        return
    commands = [('process-tree', ['ps', '-axo', 'pid=,ppid=,pgid=,stat=']),
                ('host-fds', ['lsof', '-nP', '-p', str(a.pid), '-F', 'pfta'])]
    for label, command in commands:
        try:
            completed = run_tool('ps-tree' if label == 'process-tree' else 'lsof',
                                 'guest-process-tree' if label == 'process-tree' else 'guest-descriptors', command,
                                 observations=result['tool_observations'], limit=2,
                                 pid=a.pid, capture_output=True, text=True)
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
                sample = run_tool('sample', 'guest-all-threads',
                                  ['/usr/bin/sample', str(a.pid), '2', '10', '-mayDie', '-file', str(raw)],
                                  observations=result['tool_observations'], limit=4, pid=a.pid,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
                    end = time.monotonic()
                    result['observation_ended_monotonic_seconds'] = end
                    result['observation_elapsed_seconds'] = max(0, end - start)
                    save()
                    return
                lldb = run_tool('lldb', 'guest-snapshot', ['xcrun', 'lldb', '--batch', '-p', str(a.pid),
                    '-o', 'command script import "' + str(plugin) + '"',
                    '-o', 'dsh-guest-snapshot'],
                    observations=result['tool_observations'], limit=8, pid=a.pid,
                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                result['lldb_exit_status'] = lldb.returncode
            except (OSError, subprocess.TimeoutExpired) as e:
                result['lldb_error'] = type(e).__name__
    else:
        result['sample_error'] = 'macOS-only; no fabricated sample'
    end = time.monotonic()
    result['observation_ended_monotonic_seconds'] = end
    result['observation_elapsed_seconds'] = max(0, end - start)
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
