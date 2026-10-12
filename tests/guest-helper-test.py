#!/usr/bin/env python3
"""Run the actual Bash helper and Python supervisor, not a simulated wait."""
import argparse
import errno
import importlib.util
import json
import os
import http.client
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
p = argparse.ArgumentParser()
p.add_argument('--bash', required=True)
args, remaining = p.parse_known_args()
spec = importlib.util.spec_from_file_location('refusal', HERE / 'check-bridge-refusal.py')
refusal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refusal)
runner_spec = importlib.util.spec_from_file_location('guest_runner', HERE / 'guest-runner.py')
runner = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(runner)
TEXT = 'TOOL-RESULT-BEGIN Error: missing or wrong bridge token [unauthorized] TOOL-RESULT-END'
EVENTS = [dict(phase='wrong-token', service='bridge', kind='request', request_id='1', route='/v1/shortcut/run', method='POST'),
          dict(phase='wrong-token', service='bridge', kind='response_finished', request_id='1', status=401, unauthorized=True),
          dict(phase='wrong-token', service='mock', kind='request'),
          dict(phase='wrong-token', service='mock', kind='tool_result', unauthorized=True)]


class HelperTest(unittest.TestCase):
    def invoke(self, code, timeout=0.5, tee=False, sample=0, initial=0, ps_delay=False, stdin=None, missing_stdin=False):
        with tempfile.TemporaryDirectory(prefix='dsh-helper-test-') as tmp:
            root = Path(tmp)
            ish = root / 'ish'
            # The fixture ignores emulator args; the supervisor is unchanged.
            ish.write_text('#!/usr/bin/env python3\n' + code + '\n')
            ish.chmod(0o755)
            events = root / 'events.jsonl'
            events.write_text('\n'.join(json.dumps(r) for r in EVENTS) + '\n')
            env = os.environ.copy()
            input_argument = ''
            if stdin is not None or missing_stdin:
                input_file = root / 'installer input.mjs'
                if not missing_stdin:
                    input_file.write_bytes(stdin)
                env['GUEST_INPUT_FILE'] = str(input_file)
                input_argument = ' "$GUEST_INPUT_FILE"'
            env.update(HERE=str(HERE), WORK=tmp, ISH_BUILD=tmp, GUEST_TIMEOUT=str(timeout),
                       DSH_TEST_EVENT_LOG=str(events), DSH_TEST_PHASE_FILE=str(root / 'phase'),
                       DSH_GUEST_SAMPLE_AFTER=str(sample), DSH_GUEST_INITIAL_SAMPLE_AFTER=str(initial))
            if ps_delay:
                wrapper = root / 'ps'
                wrapper.write_text('#!/bin/sh\n/bin/sleep 0.15\nexec /bin/ps "$@"\n')
                wrapper.chmod(0o755)
                env['PATH'] = tmp + os.pathsep + env['PATH']
            script = 'set -uo pipefail\nGUEST_SEQUENCE=0; GUEST_FAILURES=0\n. "$HERE/guest-helper.sh"\n'
            script += 'trap \'true\' EXIT\n'
            script += ('guest ignored wrong-token' + input_argument + ' | tee "$WORK/output"; rc=$?\n' if tee
                       else 'guest ignored wrong-token' + input_argument + ' > "$WORK/output"; rc=$?\n')
            script += 'true\nprintf "%s" "$rc" > "$WORK/shell-status"\nexit "$rc"\n'
            done = subprocess.run([args.bash, '-c', script], env=env, capture_output=True, text=True, timeout=10)
            self.assertTrue((root / 'guest-diagnostics/wrong-token/result.json').exists(), done.stderr)
            result = json.loads((root / 'guest-diagnostics/wrong-token/result.json').read_text())
            output = (root / 'output').read_text()
            self.assertEqual(done.returncode, int((root / 'shell-status').read_text()))
            self.assertEqual(result['helper_exit_status'], done.returncode)
            self.assertEqual(result['reader_processes'], 0)
            return result, output

    def test_large_stdin_is_not_copied_into_arguments_or_left_in_a_pipe(self):
        payload = b'x' * 128000
        r, output = self.invoke('import sys\nassert max(map(len,sys.argv)) < 100\n'
            'assert sys.stdin.buffer.read() == b"x" * 128000\nprint("INPUT_OK")',
            timeout=2, stdin=payload)
        self.assertEqual(r['wait_status'], 0)
        self.assertFalse(r['timed_out'])
        self.assertEqual(output.strip(), 'INPUT_OK')
        self.assertEqual(r['descendants_at_exit'], [])
        self.assertEqual(r['residual_processes'], [])
        self.assertTrue(r['pipe_eof'])

    def test_stdin_nonzero_exit_is_preserved_through_tee_and_cleanup(self):
        r, output = self.invoke('import sys\nassert sys.stdin.buffer.read() == b"input"\n'
            'print("READ_OK")\nraise SystemExit(73)', timeout=2, stdin=b'input', tee=True)
        self.assertEqual(r['wait_status'], 73 << 8)
        self.assertEqual(r['helper_exit_status'], 73)
        self.assertEqual(output.strip(), 'READ_OK')

    def test_missing_stdin_fails_before_starting_a_guest(self):
        r, output = self.invoke('raise AssertionError("must not start")', timeout=2, missing_stdin=True)
        self.assertEqual(r['helper_exit_status'], 125)
        self.assertIsNone(r['host_pid'])
        self.assertIsNone(r['wait_status'])
        self.assertEqual(r['runner_error'], 'FileNotFoundError')
        self.assertFalse(r['timed_out'])
        self.assertEqual(output, '')

    def test_prepared_session_installer_uses_a_short_launcher(self):
        with tempfile.TemporaryDirectory(prefix='dsh-installer-test-') as tmp:
            output = Path(tmp) / 'installer.mjs'
            command = subprocess.check_output([sys.executable, str(HERE / 'session-lease-prepare.py'),
                '--output', str(output), '--include-guest-test'], text=True).strip()
            self.assertEqual(command, 'node --input-type=module -')
            self.assertLess(len(command.encode()), 256)
            self.assertGreater(output.stat().st_size, 4096)

    def test_stdin_unauthorized_then_timeout_still_fails(self):
        r, output = self.invoke('import sys,time\nassert sys.stdin.buffer.read() == b"input"\n'
            'print(' + repr(TEXT) + ', flush=True)\ntime.sleep(20)', stdin=b'input', tee=True)
        self.assertEqual(r['wait_status'], 14)
        self.assertTrue(r['timed_out'])
        self.assertEqual(r['helper_exit_status'], 142)
        self.assertFalse(all(refusal.verify(r, output, EVENTS).values()))

    def test_prelaunch_setup_errors_update_the_actual_helper_status(self):
        for failure in ('diagnostic-directory', 'phase-file'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix='dsh-helper-setup-') as tmp:
                root = Path(tmp)
                if failure == 'diagnostic-directory':
                    (root / 'guest-diagnostics').write_text('not a directory')
                phase = root / 'phase'
                if failure == 'phase-file':
                    phase.mkdir()
                env = os.environ.copy()
                env.update(HERE=str(HERE), WORK=tmp, DSH_TEST_PHASE_FILE=str(phase))
                script = 'set -uo pipefail\nGUEST_SEQUENCE=0; GUEST_FAILURES=0; GUEST_STATUS=0\n'
                script += '. "$HERE/guest-helper.sh"\n'
                script += 'if guest ignored wrong-token; then exit 99; else rc=$?; fi\n'
                script += 'test "$rc" = 125 && test "$GUEST_STATUS" = 125 && test "$GUEST_FAILURES" = 1\n'
                done = subprocess.run([args.bash, '-c', script], env=env, capture_output=True, timeout=5)
                self.assertEqual(done.returncode, 0, done.stderr)

    def test_parent_input_close_error_keeps_supervising_the_real_child(self):
        with tempfile.TemporaryDirectory(prefix='dsh-input-close-') as tmp:
            root = Path(tmp)
            input_path = root / 'input'
            input_path.write_bytes(b'input')
            source = input_path.open('rb')
            class CloseFailure:
                def fileno(self): return source.fileno()
                def close(self):
                    source.close()
                    raise OSError(errno.EIO, 'injected parent input close failure')
            options = argparse.Namespace(result=root / 'result.json', phase='stdin-close', events=root / 'events',
                timeout=2, sample_after=0, initial_sample_after=0, stdin_file=input_path,
                command=[sys.executable, '-c', 'import sys; assert sys.stdin.buffer.read() == b"input"'])
            with mock.patch.object(runner, 'open', return_value=CloseFailure(), create=True):
                status = runner.run(options)
            result = json.loads(options.result.read_text())
            self.assertEqual(result['wait_status'], 0)
            self.assertEqual(status, 125)
            self.assertEqual(result['runner_error'], 'OSError')
            self.assertEqual(result['residual_processes'], [])
            self.assertTrue(source.closed)

    def test_unauthorized_then_timeout_fails(self):
        r, output = self.invoke('import time\nprint(' + repr(TEXT) + ', flush=True)\ntime.sleep(20)', tee=True)
        self.assertTrue(r['timed_out'])
        self.assertEqual(r['signal'], 14)
        self.assertEqual(r['wait_status'], 14)
        self.assertEqual(r['timeout_kind'], 'business-output-then-timeout')
        self.assertNotEqual(r['helper_exit_status'], 0)
        self.assertFalse(all(refusal.verify(r, output, EVENTS).values()))

    def test_pure_timeout_fails(self):
        r, output = self.invoke('import time\ntime.sleep(20)')
        self.assertEqual(output, '')
        self.assertEqual(r['timeout_kind'], 'no-business-output-timeout')
        self.assertEqual(r['helper_exit_status'], 142)

    def test_normal_unauthorized_zero_passes(self):
        r, output = self.invoke('print(' + repr(TEXT) + ')', timeout=2, tee=True)
        self.assertEqual(r['wait_status'], 0)
        self.assertTrue(all(refusal.verify(r, output, EVENTS).values()))

    def test_unexpected_exit_is_preserved(self):
        r, output = self.invoke('print(' + repr(TEXT) + ')\nraise SystemExit(73)', timeout=2, tee=True)
        self.assertEqual(r['wait_status'], 73 << 8)
        self.assertEqual(r['helper_exit_status'], 73)
        self.assertFalse(all(refusal.verify(r, output, EVENTS).values()))

    def test_late_observed_zero_exit_cannot_pass_deadline(self):
        r, output = self.invoke('print(' + repr(TEXT) + ')', timeout=0.05, ps_delay=True)
        self.assertEqual(r['wait_status'], 0)
        self.assertEqual(r['exit_code'], 0)
        self.assertTrue(r['timed_out'])
        self.assertFalse(r['completed_before_deadline'])
        self.assertEqual(r['helper_exit_status'], 124)
        self.assertFalse(all(refusal.verify(r, output, EVENTS).values()))

    def test_alarm_clock_is_not_business_output(self):
        r, output = self.invoke('import time\nprint("Alarm clock", flush=True)\ntime.sleep(20)')
        self.assertFalse(r['business_output'])
        self.assertEqual(output, '')

    def test_ignored_alarm_ends_with_sigkill(self):
        r, _ = self.invoke('import signal,time\nsignal.signal(signal.SIGALRM, signal.SIG_IGN)\ntime.sleep(20)')
        self.assertEqual(r['signal'], 9)
        self.assertEqual(r['wait_status'], 9)
        self.assertTrue(r['timed_out'])

    def test_group_signal_denial_keeps_real_wait_status(self):
        with tempfile.TemporaryDirectory(prefix='dsh-signal-test-') as tmp:
            result = Path(tmp) / 'result.json'
            options = argparse.Namespace(result=result, phase='signal-test', events=Path(tmp) / 'events',
                timeout=0.5, sample_after=0, initial_sample_after=0,
                command=[sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGALRM, signal.SIG_IGN); time.sleep(20)'])
            with mock.patch.object(runner.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'injected group denial')):
                status = runner.run(options)
            r = json.loads(result.read_text())
            self.assertEqual(r['wait_status'], 9)
            self.assertEqual(status, 137)
            self.assertTrue(r['timed_out'])
            self.assertTrue(r['signal_errors'])
            self.assertEqual(r['residual_processes'], [])
            self.assertIsNone(r['runner_error'])

    def test_denied_all_signals_is_unknown_failure_not_zero(self):
        with tempfile.TemporaryDirectory(prefix='dsh-signal-test-') as tmp:
            result = Path(tmp) / 'result.json'
            options = argparse.Namespace(result=result, phase='signal-test', events=Path(tmp) / 'events',
                timeout=0.1, sample_after=0, initial_sample_after=0,
                command=[sys.executable, '-c', 'import time; time.sleep(20)'])
            try:
                with mock.patch.object(runner.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'injected group denial')), \
                     mock.patch.object(runner.os, 'kill', side_effect=PermissionError(errno.EPERM, 'injected leader denial')):
                    status = runner.run(options)
                r = json.loads(result.read_text())
                self.assertEqual(status, 125)
                self.assertIsNone(r['wait_status'])
                self.assertEqual(r['exit_kind'], 'unknown')
                self.assertTrue(r['residual_processes'])
                self.assertTrue(r['signal_errors'])
            finally:
                if result.exists():
                    pid = json.loads(result.read_text())['host_pid']
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)

    def test_trapped_alarm_exit_zero_still_fails(self):
        r, _ = self.invoke('import signal,time\nsignal.signal(signal.SIGALRM, lambda a,b: exit(0))\ntime.sleep(20)')
        self.assertEqual(r['exit_code'], 0)
        self.assertEqual(r['helper_exit_status'], 124)
        self.assertTrue(r['timed_out'])

    def test_spontaneous_sigalarm_is_distinct(self):
        r, _ = self.invoke('import os,signal\nos.kill(os.getpid(), signal.SIGALRM)', timeout=2)
        self.assertFalse(r['timed_out'])
        self.assertEqual(r['signal'], 14)

    def test_redacts_output(self):
        _, output = self.invoke('print("API_KEY=secret-value Token=secret-token Authorization=Bearer secret-value")', timeout=2)
        self.assertNotIn('secret', output)

    def test_redaction_filters_only_standalone_known_noise(self):
        warning = 'Warning: disabling flag --expose_wasm due to conflicting flags'
        diagnostic = 'AssertionError {"diagnostic":' + json.dumps(warning + '\nEPERM') + '}\n'
        business = 'expose_wasm configuration failed; Alarm clock is the captured child message\n'
        source = ' \t' + warning + ' \r\n\tAlarm clock \n' + diagnostic + business
        self.assertEqual(runner.redact_output(source), diagnostic + business)
        self.assertEqual(runner.redact_output(warning), '')
        self.assertEqual(runner.redact_output(' Alarm clock '), '')
        self.assertEqual(runner.redact_output('Warning: expose_wasm unknown warning\n'),
                         'Warning: expose_wasm unknown warning\n')

    def test_mixed_warning_diagnostic_survives_and_credentials_stay_redacted(self):
        warning = 'Warning: disabling flag --expose_wasm due to conflicting flags'
        diagnostic = 'AssertionError ' + json.dumps({'diagnostic': warning + '\nEPERM'})
        line = diagnostic + ' API_KEY=private-key; Token=private-token; Bearer private-bearer\n'
        expected = diagnostic + ' API_KEY=<redacted>; Token=<redacted>; Bearer <redacted>\n'
        self.assertEqual(runner.redact_output(line), expected)
        r, output = self.invoke('print(' + repr(warning) + ')\nprint(' + repr(line.rstrip('\n')) + ')\n'
                                'raise SystemExit(73)', timeout=2, tee=True)
        self.assertEqual(output, expected)
        self.assertTrue(r['business_output'])
        self.assertEqual(r['wait_status'], 73 << 8)
        self.assertEqual(r['exit_code'], 73)
        self.assertEqual(r['helper_exit_status'], 73)
        self.assertFalse(r['timed_out'])
        self.assertTrue(r['completed_before_deadline'])

    def test_standalone_warning_then_timeout_has_no_business_output(self):
        warning = 'Warning: disabling flag --expose_wasm due to conflicting flags'
        r, output = self.invoke('import time\nprint(' + repr(warning) + ', flush=True)\ntime.sleep(20)')
        self.assertEqual(output, '')
        self.assertFalse(r['business_output'])
        self.assertEqual(r['timeout_kind'], 'no-business-output-timeout')
        self.assertEqual(r['wait_status'], 14)
        self.assertEqual(r['helper_exit_status'], 142)
        self.assertTrue(r['timed_out'])

    def test_mixed_warning_business_output_then_timeout_remains_failure(self):
        diagnostic = 'AssertionError {"diagnostic":"Warning: disabling flag --expose_wasm due to conflicting flags\\nEPERM"}'
        line = diagnostic + ' Token=private-token; ' + TEXT
        r, output = self.invoke('import time\nprint(' + repr(line) + ', flush=True)\ntime.sleep(20)', tee=True)
        self.assertIn(diagnostic, output)
        self.assertIn('Token=<redacted>;', output)
        self.assertNotIn('private-token', output)
        self.assertTrue(r['business_output'])
        self.assertEqual(r['timeout_kind'], 'business-output-then-timeout')
        self.assertEqual(r['wait_status'], 14)
        self.assertEqual(r['helper_exit_status'], 142)
        self.assertTrue(r['timed_out'])
        self.assertFalse(all(refusal.verify(r, output, EVENTS).values()))

    def test_embedded_alarm_clock_is_business_output(self):
        line = 'AssertionError {"diagnostic":"Alarm clock", "error":"EPERM"}'
        r, output = self.invoke('print(' + repr(line) + ')', timeout=2)
        self.assertEqual(output, line + '\n')
        self.assertTrue(r['business_output'])
        self.assertEqual(r['wait_status'], 0)
        self.assertFalse(r['timed_out'])

    def test_missing_bridge_evidence_rejected(self):
        r, output = self.invoke('print(' + repr(TEXT) + ')', timeout=2)
        self.assertFalse(all(refusal.verify(r, output, []).values()))

    def test_500_not_auth_refusal(self):
        r, output = self.invoke('print(' + repr(TEXT) + ')', timeout=2)
        rows = [dict(row) for row in EVENTS]
        rows[1]['status'] = 500
        self.assertFalse(all(refusal.verify(r, output, rows).values()))

    def test_diagnostic_observer_does_not_extend_deadline(self):
        r, _ = self.invoke('import time\ntime.sleep(20)', sample=0.15)
        self.assertTrue(r['timed_out'])
        self.assertEqual(r['signal'], 14)
        self.assertLess(r['elapsed_seconds'], 3)
        self.assertEqual(len(r['samples']), 1)

    def test_inherited_pipe_reader_is_rejected_and_child_killed(self):
        r, _ = self.invoke('import os,time\nif os.fork() == 0:\n time.sleep(20)\nelse:\n os._exit(0)', timeout=2)
        self.assertEqual(r['exit_code'], 0)
        self.assertEqual(r['helper_exit_status'], 125)
        self.assertTrue(r['descendants_at_exit'])
        self.assertFalse(r['pipe_eof'])

    def test_bridge_receipts_and_partial_tcp_are_redacted(self):
        with tempfile.TemporaryDirectory(prefix='dsh-service-test-') as tmp:
            root = Path(tmp)
            events = root / 'events.jsonl'
            events.write_text('')
            phase = root / 'phase'
            phase.write_text('wrong-token')
            env = os.environ.copy()
            env.update(DSH_TEST_EVENT_LOG=str(events), DSH_TEST_PHASE_FILE=str(phase))
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            server = subprocess.Popen(['node', str(HERE / 'stub-bridge.mjs'), str(port), 'test-credential'],
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.2): pass
                        break
                    except OSError:
                        if time.monotonic() >= deadline: raise
                        time.sleep(0.02)
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
                connection.request('POST', '/v1/shortcut/run?token=private-sentinel',
                                   body='private-sentinel', headers={'Authorization': 'Bearer private-sentinel'})
                response = connection.getresponse()
                self.assertEqual(response.status, 401)
                response.read()
                connection.close()
                phase.write_text('partial')
                with socket.create_connection(('127.0.0.1', port), timeout=1) as partial:
                    partial.sendall(b'POST /v1/shortcut/run HTTP/1.1\r\nX-Test: private-sentinel')
                    time.sleep(0.1)
                time.sleep(0.1)
                text = events.read_text()
                self.assertNotIn('private-sentinel', text)
                self.assertNotIn('test-credential', text)
                rows = [json.loads(s) for s in text.splitlines()]
                self.assertTrue(any(r['kind'] == 'response_finished' and r.get('status') == 401 for r in rows))
                partial_rows = [r for r in rows if r['phase'] == 'partial']
                self.assertTrue(any(r['kind'] == 'tcp_accepted' for r in partial_rows))
                self.assertTrue(any(r['kind'] == 'tcp_read' and r['received_bytes'] > 0 for r in partial_rows))
                self.assertFalse(any(r['kind'] == 'request' for r in partial_rows))
            finally:
                server.kill()
                server.wait()

    @unittest.skipUnless(sys.platform == 'darwin', 'requires real macOS sample/LLDB; run in CI')
    def test_parent_wait_status_survives_real_lldb_attach(self):
        r, output = self.invoke('import time\nprint(' + repr(TEXT) + ', flush=True)\ntime.sleep(5)',
                                timeout=9, initial=0.5)
        self.assertEqual(r['wait_status'], 0)
        self.assertEqual(r['helper_exit_status'], 0)
        self.assertFalse(r['timed_out'])
        self.assertIsNone(r['runner_error'])
        self.assertEqual(len(r['samples']), 1)
        self.assertTrue(all(refusal.verify(r, output, EVENTS).values()))

    @unittest.skipUnless(sys.platform == 'darwin', 'requires real macOS sample/LLDB; run in CI')
    def test_real_macos_sample_and_read_only_lldb(self):
        with tempfile.TemporaryDirectory(prefix='dsh-observer-test-') as tmp:
            root = Path(tmp)
            source = root / 'observer.c'
            source.write_text('#include <unistd.h>\n#include <pthread.h>\n'
                'static int admission_enabled; static int lifecycle_state;\n'
                'void *worker(void *p) { while (1) sleep(1); }\n'
                'int main(void) { pthread_t t; pthread_create(&t, 0, worker, 0); '
                'while (!admission_enabled && !lifecycle_state) sleep(1); }\n')
            binary = root / 'observer'
            subprocess.run(['cc', '-g', '-O0', str(source), '-o', str(binary)], check=True, capture_output=True)
            events = root / 'events.jsonl'
            events.write_text('')
            inferior = subprocess.Popen([str(binary)])
            try:
                subprocess.run([sys.executable, str(HERE / 'guest-observer.py'), '--pid', str(inferior.pid),
                    '--phase', 'selftest', '--output', str(root / 'sample'), '--events', str(events),
                    '--executable', str(binary)], check=True, timeout=18)
                observer = json.loads((root / 'sample/observer.json').read_text())
                state = json.loads((root / 'sample/guest-state.json').read_text())
                self.assertEqual(observer['sample_exit_status'], 0)
                self.assertTrue(observer['sample_frames'])
                # Command detaches itself, so LLDB's following detach can report
                # "not attached". The saved state, not CLI status, proves success.
                self.assertGreaterEqual(len(state['threads']), 2)
                self.assertEqual(state['lifecycle']['admission_enabled'], 0)
                self.assertTrue(state['stopped_read_only'])
            finally:
                inferior.kill()
                inferior.wait()


if __name__ == '__main__':
    version = subprocess.check_output([args.bash, '-c', 'printf "%s" "$BASH_VERSION"'], text=True)
    print('Actual helper tests under Bash', version, flush=True)
    unittest.main(argv=[__file__] + remaining, verbosity=2)
