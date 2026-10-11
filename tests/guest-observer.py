#!/usr/bin/env python3
"""External observer; raw system samples stay private and are never uploaded."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def process_identity(pid):
    try:
        env = os.environ.copy()
        env['LC_ALL'] = 'C'
        value = subprocess.check_output(['ps', '-p', str(pid), '-o', 'pgid=,lstart='],
                                        text=True, timeout=1, env=env)
        return ' '.join(value.split()) or None
    except (OSError, subprocess.SubprocessError): return None


def collect(a):
    a.output.mkdir(parents=True, exist_ok=True)
    result = dict(host_pid=a.pid, phase=a.phase)
    identity = a.start_identity or process_identity(a.pid)
    result['host_start_identity'] = identity
    def same_process():
        return identity is not None and identity != 'unknown' and process_identity(a.pid) == identity
    def save():
        (a.output / 'observer.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
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
                frames = []
                for line in raw.read_text(errors='replace').splitlines():
                    # Keep call-stack lines, discard all headers and binary/path sections.
                    m = re.match(r'\s*[+!:| ]*\d+ ([a-zA-Z_][a-zA-Z0-9_:$<>~.* ()+,-]*?)\s+\(in ([a-zA-Z0-9_.-]+)\)(.*)', line)
                    if m: frames.append(dict(function=m[1], image=m[2]))
                    elif re.match(r'\s*\d+ Thread_\d+', line):
                        frames.append(dict(thread=re.search(r'Thread_\d+', line)[0]))
                result['sample_frames'] = frames
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
    collect(p.parse_args())
