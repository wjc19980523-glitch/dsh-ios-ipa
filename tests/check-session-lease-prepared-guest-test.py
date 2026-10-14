#!/usr/bin/env python3
"""Receipts never override timeouts, status, reader or cleanup failure."""
import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('prepared_checker', Path(__file__).with_name('check-session-lease-prepared-guest.py'))
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def evidence():
    result = dict(phase='session-prepared-safety-zstd', host_pid=101, wait_status=0,
                  exit_kind='exited', exit_code=0, signal=None, timed_out=False,
                  completed_before_deadline=True, helper_exit_status=0, reader_processes=0,
                  runner_error=None, signal_errors=[], descendants_at_exit=[], residual_processes=[], pipe_eof=True)
    text = '\n'.join([f'PASS assertion {i}' for i in range(11)] + [
        'SESSION_PREPARED_GUEST_TESTS 11/11; native_flock_executed=true; mode=safety; encoding=zstd'])
    return result, text


class Receipts(unittest.TestCase):
    def verify(self, result, text):
        return CHECKER.verify(result, text, 'safety', 'zstd')

    def test_complete_real_exit(self):
        self.assertTrue(self.verify(*evidence()))

    def test_expected_output_then_timeout(self):
        result, text = evidence(); result.update(timed_out=True, completed_before_deadline=False, signal=14, wait_status=14)
        self.assertFalse(self.verify(result, text))

    def test_pure_timeout(self):
        result, _ = evidence(); result.update(timed_out=True, signal=14)
        self.assertFalse(self.verify(result, 'Alarm clock'))

    def test_nonzero_wait_or_helper(self):
        for key in ('wait_status', 'exit_code', 'helper_exit_status'):
            result, text = evidence(); result[key] = 1
            self.assertFalse(self.verify(result, text))

    def test_cleanup_is_required(self):
        for key, value in (('reader_processes', 1), ('descendants_at_exit', [123]),
                           ('residual_processes', [456]), ('pipe_eof', False), ('signal_errors', ['EIO'])):
            result, text = evidence(); result[key] = value
            self.assertFalse(self.verify(result, text))

    def test_missing_or_duplicate_assertions(self):
        result, text = evidence()
        self.assertFalse(self.verify(result, text.replace('PASS assertion 0\n', '')))
        self.assertFalse(self.verify(result, 'PASS assertion 0\n' + text))
        self.assertFalse(self.verify(result, ' PASS disguised extra\n' + text))

    def test_wrong_case_or_error_text(self):
        result, text = evidence(); result['phase'] = 'session-prepared-safety-none'
        self.assertFalse(self.verify(result, text))
        result, text = evidence(); self.assertFalse(self.verify(result, text + '\nAssertionError: injected'))

    def test_boolean_zero_and_missing_status_are_rejected(self):
        result, text = evidence(); result['wait_status'] = False
        self.assertFalse(self.verify(result, text))
        result, text = evidence(); del result['timed_out']
        self.assertFalse(self.verify(result, text))

    def test_large_requires_real_full_clean_and_dirty_counts(self):
        import json
        result, _ = evidence(); result['phase'] = 'session-prepared-large-none'
        metrics = dict(encoding='none', physical_log_bytes=[1, 2, 3, 4], semantic_title_bytes=11141120,
                       full={'background_full_decode_count': 4},
                       clean={'background_full_decode_count': 0, 'prepared_verified_count': 4, 'raw_verified_bytes': 10},
                       dirty={'background_full_decode_count': 1, 'prepared_verified_count': 3})
        footer = 'SESSION_PREPARED_GUEST_TESTS 1/1; native_flock_executed=true; mode=large; encoding=none'
        text = 'PASS large assertion\nSESSION_PREPARED_TIMING ' + json.dumps(metrics) + '\n' + footer
        self.assertTrue(CHECKER.verify(result, text, 'large', 'none'))
        metrics['clean']['background_full_decode_count'] = 1
        text = 'PASS large assertion\nSESSION_PREPARED_TIMING ' + json.dumps(metrics) + '\n' + footer
        self.assertFalse(CHECKER.verify(result, text, 'large', 'none'))


if __name__ == '__main__':
    unittest.main()
