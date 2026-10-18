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


def process_group(pgid, timeout=1, diagnostic=None):
    # No argv, environment, paths or user names enter diagnostics.
    rows = []
    details = dict(status='unconfirmed', rows_seen=0, matched_rows=0)
    try:
        ps = subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,stat='],
                            capture_output=True, text=True, timeout=timeout)
        if ps.returncode != 0:
            details.update(status='ps-nonzero', return_code=ps.returncode)
            return None
        for line in ps.stdout.splitlines():
            parts = line.split()
            if not parts: continue
            details['rows_seen'] += 1
            malformed = ('field-count' if len(parts) != 4 else
                'numeric-field' if not all(re.fullmatch(r'[0-9]+', part) for part in parts[:3]) else
                'state-field' if not re.fullmatch(r'[A-Za-z+<>Nls0-9-]+', parts[3]) else None)
            if malformed:
                details.update(status='malformed-row', malformed_kind=malformed)
                return None
            if int(parts[2]) == pgid:
                rows.append(dict(pid=int(parts[0]), ppid=int(parts[1]),
                                 pgid=int(parts[2]), state=parts[3]))
                details['matched_rows'] += 1
        details['status'] = 'confirmed'
    except subprocess.TimeoutExpired:
        details['status'] = 'timeout'
        return None
    except OSError as error:
        details.update(status='os-error', errno=error.errno)
        return None
    except ValueError:
        details.update(status='malformed-row', malformed_kind='value-error')
        return None  # Unknown is never a clean process group.
    finally:
        if diagnostic is not None:
            diagnostic.clear()
            diagnostic.update(details)
    return rows


def observer_cleanup_succeeded(sample):
    if sample['residual_processes'] != [] or sample['cleanup_errors']:
        return False
    return sample['exit_status'] == 0 or (
        sample['exit_status'] == -signal.SIGKILL and sample['forced_cleanup'] and
        sample['cleanup_reason'] == 'observer-cleanup-deadline')


def stop_observers(observers):
    samples = []
    for label, observer in observers:
        sample = dict(label=label, observer_pid=observer.pid, observer_pgid=observer.pid,
                      exit_status=None, forced_cleanup=False, cleanup_reason=None,
                      cleanup_errors=[], residual_processes=None,
                      residual_query=dict(status='not-requested'))
        try:
            observer.wait(timeout=2)  # Preserve the original natural-exit allowance.
        except subprocess.TimeoutExpired:
            sample['cleanup_reason'] = 'observer-cleanup-deadline'
        except OSError as error:
            sample['cleanup_reason'] = 'observer-wait-error'
            sample['cleanup_errors'].append(dict(operation='wait', errno=error.errno))
        # The old post-SIGKILL wait was unbounded. Reap and group verification
        # now share one second, independently of the business deadline.
        tail_deadline = time.monotonic() + 1
        if sample['cleanup_reason'] and observer.returncode is None:
            # This direct child has not been reaped, so its PID/PGID cannot have
            # been recycled. Never signal an old group after reaping its leader.
            try:
                os.killpg(observer.pid, signal.SIGKILL)
                sample['forced_cleanup'] = True
            except ProcessLookupError:
                pass
            except OSError as error:
                sample['cleanup_errors'].append(dict(operation='signal-group', errno=error.errno))
            try:
                observer.wait(timeout=max(0, tail_deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                sample['cleanup_errors'].append(dict(operation='reap', error='TimeoutExpired'))
            except OSError as error:
                sample['cleanup_errors'].append(dict(operation='reap', errno=error.errno))
        sample['exit_status'] = observer.returncode
        while time.monotonic() < tail_deadline:
            sample['residual_processes'] = process_group(observer.pid,
                timeout=min(1, tail_deadline - time.monotonic()), diagnostic=sample['residual_query'])
            if sample['residual_processes'] == [] or sample['residual_processes'] is None:
                break
            if not sample['forced_cleanup']:
                break  # Report remaining children; do not signal a reaped leader's old group.
            time.sleep(min(.02, max(0, tail_deadline - time.monotonic())))
        if sample['residual_processes'] is None:
            sample['cleanup_errors'].append(dict(operation='inspect-group', error='Unconfirmed'))
        sample['cleanup_confirmed'] = observer_cleanup_succeeded(sample)
        samples.append(sample)
    return samples


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
    identity = None
    selector = None
    raw_status = None
    reaped_at = None
    timed_out = False
    eof = False
    chunks = []
    observers = []
    samples = []
    sampled = set()
    descendants = None
    process_queries = dict(descendants_at_exit=dict(status='not-requested'),
                           before_cleanup=dict(status='not-requested'), residual_processes=dict(status='not-requested'))
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
        # Every resource created after Popen belongs to this supervision scope.
        # Partial pipe/selector initialization must still reap the real child.
        identity = process_identity(p.pid)
        os.set_blocking(p.stdout.fileno(), False)
        selector = selectors.DefaultSelector()
        selector.register(p.stdout, selectors.EVENT_READ)
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
                    descendants = process_group(p.pid, diagnostic=process_queries['descendants_at_exit'])
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
                    observer_command = [sys.executable, str(Path(__file__).with_name('guest-observer.py')),
                        '--pid', str(p.pid), '--phase', a.phase, '--output', str(destination),
                        '--start-identity', identity or 'unknown',
                        '--events', str(a.events), '--executable', str(Path(a.command[0]).resolve())]
                    if getattr(a, 'host_only', False):
                        observer_command.append('--host-only')
                    observer = subprocess.Popen(observer_command,
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
        if selector is not None:
            try:
                selector.close()
            except OSError as error:
                if runner_error is None:
                    runner_error = type(error).__name__
        try:
            p.stdout.close()
        except OSError as error:
            if runner_error is None:
                runner_error = type(error).__name__
        before_cleanup = process_group(p.pid, diagnostic=process_queries['before_cleanup'])
        if before_cleanup:
            send(signal.SIGKILL)
        # Sampling is independent of the deadline. It is also owned and reaped.
        samples = stop_observers(observers)
        if any(not sample['cleanup_confirmed'] for sample in samples) and runner_error is None:
            runner_error = 'ObserverCleanupFailure'
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

    residual = process_group(p.pid, diagnostic=process_queries['residual_processes'])
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
                  process_group_queries=process_queries,
                  reader_processes=0, helper_exit_status=status,
                  observer_wait_interruptions=observer_wait_interruptions, runner_error=runner_error,
                  signal_errors=signal_errors,
                  samples=samples)
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
    parser.add_argument('--host-only', action='store_true')
    separator = sys.argv.index('--')
    args = parser.parse_args(sys.argv[1:separator])
    args.command = sys.argv[separator + 1:]
    raise SystemExit(run(args))
