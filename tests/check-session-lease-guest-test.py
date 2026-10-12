#!/usr/bin/env python3
"""Reject false guest-suite success using actual checker CLI invocations."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
CHECKER = HERE / 'check-session-lease-guest.py'
SPEC = importlib.util.spec_from_file_location('session_guest_checker', CHECKER)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


def normal_result():
    return dict(phase='session-lease-native', host_pid=101, wait_status=0,
                exit_kind='exited', exit_code=0, signal=None, timed_out=False,
                completed_before_deadline=True, helper_exit_status=0,
                reader_processes=0, runner_error=None, descendants_at_exit=[],
                residual_processes=[], pipe_eof=True, signal_errors=[])


PASSES = ['PASS case-' + str(index) for index in range(1, 15)]
OUTPUT = '\n'.join(PASSES + [checker.RECEIPT]) + '\n'


class SessionGuestCheckerTests(unittest.TestCase):
    def cli(self, result, output):
        with tempfile.TemporaryDirectory(prefix='dsh-session-checker-') as directory:
            root = Path(directory)
            result_path = root / 'result.json'
            output_path = root / 'session-native.log'
            result_path.write_text(json.dumps(result), encoding='utf-8')
            output_path.write_text(output, encoding='utf-8')
            return subprocess.run([sys.executable, str(CHECKER), '--result', str(result_path),
                                   '--output', str(output_path)], capture_output=True, text=True, timeout=5)

    def assertRejected(self, result, output):
        done = self.cli(result, output)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertNotIn('ASSERTIONS_VERIFIED', done.stdout)

    def test_normal_fourteen_unique_passes_and_one_native_receipt_pass(self):
        done = self.cli(normal_result(), OUTPUT)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), 'SESSION_LEASE_GUEST_ASSERTIONS_VERIFIED=14')

    def test_crlf_output_from_a_complete_guest_passes(self):
        self.assertTrue(checker.verify(normal_result(), OUTPUT.replace('\n', '\r\n')))

    def test_host_zero_cannot_hide_assertion_or_missing_footer(self):
        for output in [OUTPUT + 'AssertionError [ERR_ASSERTION]: private-sentinel\n',
                       '\n'.join(PASSES) + '\n',
                       'AssertionError [ERR_ASSERTION]: private-sentinel\n']:
            with self.subTest(output=output[-70:]):
                self.assertRejected(normal_result(), output)

    def test_expected_output_before_deadline_failure_cannot_pass(self):
        for changes in [dict(timed_out=True, completed_before_deadline=False, helper_exit_status=124),
                        dict(timed_out=True), dict(completed_before_deadline=False),
                        dict(wait_status=14, exit_kind='signaled', exit_code=None, signal=14,
                             timed_out=True, helper_exit_status=142)]:
            with self.subTest(changes=changes):
                self.assertRejected(dict(normal_result(), **changes), OUTPUT)

    def test_partial_suite_and_malformed_receipts_fail(self):
        for output in ['\n'.join(PASSES[:13] + [checker.RECEIPT]) + '\n',
                       OUTPUT.replace('14/14', '13/14'),
                       OUTPUT.replace('native_flock_executed=true', 'native_flock_executed=false'),
                       OUTPUT.replace('cycles=100', 'cycles=99'),
                       OUTPUT.replace(checker.RECEIPT, checker.RECEIPT + ' trailing')]:
            with self.subTest(output=output[-100:]):
                self.assertRejected(normal_result(), output)

    def test_duplicate_or_extra_receipts_fail_even_if_one_is_correct(self):
        for duplicate in [checker.RECEIPT, checker.RECEIPT.replace('14/14', '13/14'),
                          ' ' + checker.RECEIPT]:
            with self.subTest(duplicate=duplicate):
                self.assertRejected(normal_result(), OUTPUT + duplicate + '\n')

    def test_duplicate_extra_or_whitespace_disguised_passes_fail(self):
        for output in [OUTPUT.replace(PASSES[-1] + '\n', PASSES[0] + '\n'),
                       OUTPUT.replace(checker.RECEIPT, PASSES[0] + '\n' + checker.RECEIPT),
                       OUTPUT.replace(PASSES[-1] + '\n', PASSES[0] + ' \n'),
                       OUTPUT.replace(PASSES[-1] + '\n', ' ' + PASSES[-1] + '\n')]:
            with self.subTest(output=output[-140:]):
                self.assertRejected(normal_result(), output)

    def test_footer_before_all_assertions_cannot_pass(self):
        self.assertRejected(normal_result(), checker.RECEIPT + '\n' + '\n'.join(PASSES) + '\n')

    def test_failure_after_valid_footer_cannot_pass(self):
        for failure in ['FAIL cleanup', 'TypeError: fixture failed', 'Error: cleanup failed',
                        'uncaughtException', 'unhandledRejection']:
            with self.subTest(failure=failure):
                self.assertRejected(normal_result(), OUTPUT + failure + '\n')

    def test_nonzero_unknown_or_unclean_execution_cannot_pass(self):
        for changes in [dict(wait_status=73 << 8, exit_code=73, helper_exit_status=73),
                        dict(wait_status=None, exit_kind='unknown', exit_code=None, helper_exit_status=125),
                        dict(phase='session-lease-install'), dict(host_pid=None),
                        dict(residual_processes=[dict(pid=102)]),
                        dict(descendants_at_exit=[dict(pid=102)]), dict(pipe_eof=False),
                        dict(reader_processes=1), dict(runner_error='OSError'),
                        dict(signal_errors=[dict(errno=1)]), dict(helper_exit_status=125)]:
            with self.subTest(changes=changes):
                self.assertRejected(dict(normal_result(), **changes), OUTPUT)

    def test_missing_execution_fields_and_boolean_zero_are_rejected(self):
        result = normal_result()
        for key in result:
            incomplete = result.copy()
            del incomplete[key]
            with self.subTest(missing=key):
                self.assertFalse(checker.verify(incomplete, OUTPUT))
        for key in ['wait_status', 'exit_code', 'helper_exit_status', 'reader_processes']:
            with self.subTest(boolean=key):
                self.assertFalse(checker.verify(dict(result, **{key: False}), OUTPUT))

    def test_cli_usage_and_unavailable_input_have_explicit_status_two(self):
        done = subprocess.run([sys.executable, str(CHECKER)], capture_output=True, text=True, timeout=5)
        self.assertEqual(done.returncode, 2)
        with tempfile.TemporaryDirectory(prefix='dsh-session-checker-') as directory:
            root = Path(directory)
            for contents in [None, '{invalid json']:
                result = root / 'result.json'
                if contents is not None:
                    result.write_text(contents, encoding='utf-8')
                done = subprocess.run([sys.executable, str(CHECKER), '--result', str(result),
                                       '--output', str(root / 'absent.log')],
                                      capture_output=True, text=True, timeout=5)
                self.assertEqual(done.returncode, 2)
                self.assertNotIn(str(root), done.stderr)
                self.assertNotIn('ASSERTIONS_VERIFIED', done.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
