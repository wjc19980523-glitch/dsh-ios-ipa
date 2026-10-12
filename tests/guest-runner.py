#!/usr/bin/env python3
"""Own one guest process group, output pipe and real wait status. Never retry."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time


def process_identity(pid):
    try:
        env = os.environ.copy()
        env['LC_ALL'] = 'C'
        value = subprocess.check_output(['ps', '-p', str(pid), '-o', 'pgid=,lstart='],
                                        text=True, timeout=1, env=env)
        return ' '.join(value.split()) or None
    except (OSError, subprocess.SubprocessError): return None


def process_group(pgid):
    # No argv, environment, paths or user names enter diagnostics.
    rows = []
    try:
        ps = subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,stat='],
                            capture_output=True, text=True, timeout=1)
        for line in ps.stdout.splitlines():
            parts = line.split()
            if len(parts) == 4 and int(parts[2]) == pgid:
                rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]),
                                 pgid=int(parts[2]), state=parts[3]))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None  # Unknown is never a clean process group.
    return rows


def redact_output(data):
    data = re.sub(r'(?i)Bearer\s+\S+', 'Bearer <redacted>', data)
    data = re.sub(r'(?i)((?:api[_-]?key|token|authorization)\s*[=:]\s*)[^\s,;]+',
                  r'\1<redacted>', data)
    # Filter only complete, known runtime/shell noise lines. Diagnostics can
    # quote these messages inside an AssertionError or JSON; dropping that
    # entire line would also erase the actual failure (for example EPERM).
    noise = {'Warning: disabling flag --expose_wasm due to conflicting flags',
             'Alarm clock'}
    return ''.join(line for line in data.splitlines(True)
                   if line.strip() not in noise)


def run(a):
    a.result.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    source = None
    input_close_error = None
    try:
        if getattr(a, 'stdin_file', None):
            source = open(a.stdin_file, 'rb')
        p = subprocess.Popen(a.command, stdin=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True)
    except OSError as error:
        # No child has started. Preserve an explicit infrastructure failure,
        # without logging the command, input path or input contents.
        a.result.write_text(json.dumps(dict(phase=a.phase, host_pid=None, wait_status=None,
            exit_kind='unknown', exit_code=None, signal=None, timed_out=False,
            completed_before_deadline=False, helper_exit_status=125, reader_processes=0,
            runner_error=type(error).__name__, descendants_at_exit=[], residual_processes=[],
            pipe_eof=True, business_output=False, samples=[]), indent=2) + '\n')
        return 125
    finally:
        # Popen duplicated stdin into the child; the supervisor retains no
        # input descriptor or background pipeline reader while it waits.
        if source is not None:
            try:
                source.close()
            except OSError as error:
                # The child already owns its descriptor. Keep supervising it
                # and preserve its wait status; this cannot become a pass.
                input_close_error = type(error).__name__
    identity = process_identity(p.pid)
    os.set_blocking(p.stdout.fileno(), False)
    selector = selectors.DefaultSelector()
    selector.register(p.stdout, selectors.EVENT_READ)
    raw_status = None
    reaped_at = None
    timed_out = False
    eof = False
    chunks = []
    observers = []
    sampled = set()
    descendants = None
    killed_at = None
    observer_wait_interruptions = 0
    runner_error = input_close_error
    signal_errors = []
    forced_kill_sent = False

    def send(sig):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            pass
        except OSError as error:
            signal_errors.append(dict(target='group', signal=sig, errno=error.errno))
            # Preserve failure evidence; do not let a cleanup error erase wait
            # status. Only our still-unreaped, start-identity-matched leader is
            # eligible for a direct fallback. Residual children still fail.
            if raw_status is None and identity and process_identity(p.pid) == identity:
                try: os.kill(p.pid, sig)
                except ProcessLookupError: pass
                except OSError as direct_error:
                    signal_errors.append(dict(target='leader', signal=sig, errno=direct_error.errno))

    try:
        while True:
            elapsed = time.monotonic() - started
            if raw_status is None:
                try:
                    pid, status = os.waitpid(p.pid, os.WNOHANG)
                except ChildProcessError:
                    # Darwin temporarily reparents a ptrace-attached inferior
                    # to LLDB. ECHILD during our observer is not an exit. The
                    # original parent receives the real wait status on detach.
                    if any(observer.poll() is None for _, observer in observers):
                        observer_wait_interruptions += 1
                        pid = 0
                    else:
                        raise
                if pid:
                    raw_status = status
                    p.returncode = os.waitstatus_to_exitcode(status)
                    reaped_at = time.monotonic() - started
                    if reaped_at >= a.timeout:
                        timed_out = True
                    descendants = process_group(p.pid)
            if raw_status is not None and eof:
                break
            if elapsed >= a.timeout and not timed_out and raw_status is None:
                timed_out = True
                send(signal.SIGALRM)
                killed_at = elapsed
            if timed_out and raw_status is None and elapsed >= killed_at + 0.25 and not forced_kill_sent:
                send(signal.SIGKILL)
                forced_kill_sent = True
            if timed_out and raw_status is None and elapsed >= killed_at + 1:
                break  # Signal denial is unknown/failure, never an endless wait.
            # A child inheriting stdout must not keep a reader alive indefinitely.
            if raw_status is not None and elapsed > reaped_at + 0.3:
                send(signal.SIGKILL)
                break
            for label, due in [('75-seconds', a.sample_after), ('initial', a.initial_sample_after)]:
                if due > 0 and elapsed >= due and label not in sampled and raw_status is None and not timed_out:
                    sampled.add(label)
                    destination = a.result.parent / label
                    observer = subprocess.Popen([sys.executable, str(Path(__file__).with_name('guest-observer.py')),
                        '--pid', str(p.pid), '--phase', a.phase, '--output', str(destination),
                        '--start-identity', identity or 'unknown',
                        '--events', str(a.events), '--executable', str(Path(a.command[0]).resolve())],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    observers.append((label, observer))
            for key, _ in selector.select(0.02):
                block = os.read(key.fd, 65536)
                if block: chunks.append(block)
                else:
                    eof = True
                    selector.unregister(p.stdout)
    except Exception as error:
        runner_error = type(error).__name__
    finally:
        if raw_status is None:
            send(signal.SIGKILL)
        selector.close()
        p.stdout.close()
        before_cleanup = process_group(p.pid)
        if before_cleanup:
            send(signal.SIGKILL)
        # Sampling is independent of the deadline. It is also owned and reaped.
        for _, observer in observers:
            try: observer.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try: os.killpg(observer.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                observer.wait()
        if raw_status is None:
            # Detach/observer cleanup must finish before interpreting ECHILD.
            # A genuinely lost status is unknown/failure, never invented zero.
            reap_deadline = time.monotonic() + 1
            while time.monotonic() < reap_deadline:
                try:
                    pid, status = os.waitpid(p.pid, os.WNOHANG)
                    if pid:
                        raw_status = status
                        break
                except ChildProcessError:
                    pass
                time.sleep(0.02)
            p.returncode = os.waitstatus_to_exitcode(raw_status) if raw_status is not None else 125

    residual = process_group(p.pid)
    output = redact_output(b''.join(chunks).decode('utf-8', errors='replace'))
    exited = raw_status is not None and os.WIFEXITED(raw_status)
    exit_code = os.WEXITSTATUS(raw_status) if exited else None
    sig = os.WTERMSIG(raw_status) if raw_status is not None and os.WIFSIGNALED(raw_status) else None
    status = exit_code if exited else 128 + sig if sig else 125
    clean = descendants == [] and residual == [] and eof
    if timed_out and status == 0: status = 124
    if not clean and status == 0: status = 125
    if runner_error and status == 0: status = 125
    result = dict(phase=a.phase, host_pid=p.pid, wait_status=raw_status,
                  host_start_identity=identity,
                  exit_kind='exited' if exited else 'signaled' if sig else 'unknown', exit_code=exit_code,
                  signal=sig, timed_out=timed_out, elapsed_seconds=time.monotonic() - started,
                  completed_before_deadline=reaped_at is not None and reaped_at < a.timeout,
                  business_output=bool(output.strip()),
                  timeout_kind=('business-output-then-timeout' if output.strip() else 'no-business-output-timeout') if timed_out else None,
                  descendants_at_exit=descendants, residual_processes=residual, pipe_eof=eof,
                  reader_processes=0, helper_exit_status=status,
                  observer_wait_interruptions=observer_wait_interruptions, runner_error=runner_error,
                  signal_errors=signal_errors,
                  samples=[dict(label=label, exit_status=observer.returncode) for label, observer in observers])
    a.result.write_text(json.dumps(result, indent=2) + '\n')
    sys.stdout.write(output)
    return status


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['run'])
    parser.add_argument('--phase', required=True)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--sample-after', type=float, default=75)
    parser.add_argument('--initial-sample-after', type=float, default=0)
    parser.add_argument('--events', type=Path, required=True)
    parser.add_argument('--stdin-file')
    separator = sys.argv.index('--')
    args = parser.parse_args(sys.argv[1:separator])
    args.command = sys.argv[separator + 1:]
    raise SystemExit(run(args))
