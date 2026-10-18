#!/usr/bin/env python3
"""Real owned children exercise supervisor resource-error paths without CI tools."""
import argparse
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

parser = argparse.ArgumentParser()
parser.add_argument('--runner', type=Path,
                    default=Path(__file__).with_name('guest-runner.py'))
args, remaining = parser.parse_known_args()
spec = importlib.util.spec_from_file_location('resource_runner', args.runner)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
POPEN = subprocess.Popen
WAITPID = os.waitpid


def group_absent(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False  # Inaccessible is not confirmed absent.
    return False


def finish_owned(child):
    """Failure-safe fixture cleanup; never signal a child after it was reaped."""
    raw = None
    if child.returncode is None:
        try:
            pid, raw = WAITPID(child.pid, os.WNOHANG)
            if not pid:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                pid, raw = WAITPID(child.pid, 0)
            child.returncode = os.waitstatus_to_exitcode(raw)
        except ChildProcessError:
            pass
    if child.stdout is not None:
        child.stdout.close()
    return raw


@unittest.skipUnless(hasattr(os, 'killpg'), 'requires POSIX process groups')
class RunnerResourceTest(unittest.TestCase):
    def run_child(self, code, fault=None):
        with tempfile.TemporaryDirectory(prefix='dsh-runner-resource-') as tmp:
            root = Path(tmp)
            children = []
            observed_waits = []

            def remember(*popen_args, **kwargs):
                child = POPEN(*popen_args, **kwargs)
                if kwargs.get('start_new_session'):
                    children.append(child)
                return child

            def record_wait(pid, options):
                value = WAITPID(pid, options)
                if value[0]:
                    observed_waits.append(value)
                return value

            invocation = SimpleNamespace(result=root / 'result.json',
                phase='resource-regression', command=[sys.executable, '-c', code],
                timeout=2, sample_after=0, initial_sample_after=0,
                events=root / 'events.jsonl')
            try:
                with mock.patch.object(runner.subprocess, 'Popen', side_effect=remember), \
                     mock.patch.object(runner.os, 'waitpid', side_effect=record_wait):
                    if fault is None:
                        status = runner.run(invocation)
                    else:
                        with fault():
                            status = runner.run(invocation)
                result = json.loads(invocation.result.read_text())
                self.assertEqual(len(children), 1)
                self.assertTrue(group_absent(children[0].pid))
                self.assertIn((children[0].pid, result['wait_status']), observed_waits)
                self.assertEqual(result['helper_exit_status'], status)
                self.assertEqual(result['residual_processes'], [])
                self.assertEqual(result['process_group_queries']['residual_processes']['status'], 'confirmed')
                return status, result
            finally:
                for child in children:
                    finish_owned(child)
                    self.assertTrue(group_absent(child.pid), 'fixture left an owned group')

    def test_real_success_wait_and_empty_group(self):
        status, result = self.run_child('raise SystemExit(0)')
        self.assertEqual((status, result['wait_status']), (0, 0))
        self.assertIsNone(result['runner_error'])
        self.assertTrue(result['pipe_eof'])
        self.assertFalse(result['timed_out'])

    def test_real_nonzero_wait_is_preserved(self):
        status, result = self.run_child('raise SystemExit(7)')
        self.assertEqual((status, result['wait_status']), (7, 7 << 8))
        self.assertIsNone(result['runner_error'])
        self.assertTrue(result['pipe_eof'])
        self.assertFalse(result['timed_out'])

    def assert_setup_error_reaped(self, fault):
        status, result = self.run_child('import time; time.sleep(20)', fault)
        self.assertEqual(result['wait_status'], signal.SIGKILL)
        self.assertEqual(status, 128 + signal.SIGKILL)
        self.assertEqual(result['signal'], signal.SIGKILL)
        self.assertEqual(result['runner_error'], 'OSError')
        self.assertFalse(result['timed_out'])
        self.assertFalse(result['completed_before_deadline'])
        self.assertFalse(result['pipe_eof'])
        self.assertIsNone(result['descendants_at_exit'])
        self.assertEqual(result['process_group_queries']['descendants_at_exit']['status'], 'not-requested')

    def test_set_blocking_error_reaps_owned_child(self):
        self.assert_setup_error_reaped(lambda: mock.patch.object(runner.os, 'set_blocking',
            side_effect=OSError(errno.EIO, 'controlled setup failure')))

    def test_selector_construction_error_reaps_owned_child(self):
        self.assert_setup_error_reaped(lambda: mock.patch.object(runner.selectors, 'DefaultSelector',
            side_effect=OSError(errno.EIO, 'controlled selector construction failure')))

    def test_selector_registration_error_closes_selector_and_reaps_child(self):
        selector = runner.selectors.DefaultSelector()
        original_close = selector.close
        with mock.patch.object(selector, 'close', wraps=original_close) as close:
            def fault():
                context = mock.patch.object(runner.selectors, 'DefaultSelector', return_value=selector)
                return context
            with mock.patch.object(selector, 'register',
                                   side_effect=OSError(errno.EIO, 'controlled registration failure')):
                try:
                    self.assert_setup_error_reaped(fault)
                finally:
                    if not close.called:
                        original_close()
            self.assertEqual(close.call_count, 1)

    def observer_wait_error(self):
        child = POPEN([sys.executable, '-c', 'import time; time.sleep(20)'],
                      start_new_session=True)
        original_wait = child.wait
        first = True

        def wait(*a, **kw):
            nonlocal first
            if first:
                first = False
                raise OSError(errno.EIO, 'controlled observer wait failure')
            return original_wait(*a, **kw)

        try:
            with mock.patch.object(child, 'wait', side_effect=wait):
                sample = runner.stop_observers([('resource-regression', child)])[0]
            self.assertEqual(sample['exit_status'], -signal.SIGKILL)
            self.assertEqual(sample['cleanup_reason'], 'observer-wait-error')
            self.assertTrue(sample['forced_cleanup'])
            self.assertEqual(sample['cleanup_errors'], [dict(operation='wait', errno=errno.EIO)])
            self.assertEqual(sample['residual_processes'], [])
            self.assertEqual(sample['residual_query']['status'], 'confirmed')
            self.assertFalse(sample['cleanup_confirmed'])
            self.assertTrue(group_absent(child.pid))
            return sample
        finally:
            finish_owned(child)
            self.assertTrue(group_absent(child.pid))

    def test_observer_wait_error_reaps_child_and_remains_failure(self):
        self.observer_wait_error()

    def test_observer_wait_error_with_signal_denial_keeps_unknown_failure(self):
        child = POPEN([sys.executable, '-c', 'import time; time.sleep(20)'],
                      start_new_session=True)
        original_wait = child.wait
        original_killpg = os.killpg
        first = True

        def wait(*a, **kw):
            nonlocal first
            if first:
                first = False
                raise OSError(errno.EIO, 'controlled observer wait failure')
            return original_wait(*a, **kw)

        def deny_owned_group(pgid, sig):
            if pgid == child.pid:
                raise PermissionError(errno.EPERM, 'controlled owned signal denial')
            return original_killpg(pgid, sig)

        try:
            with mock.patch.object(child, 'wait', side_effect=wait), \
                 mock.patch.object(runner.os, 'killpg', side_effect=deny_owned_group):
                sample = runner.stop_observers([('resource-regression', child)])[0]
            self.assertEqual(sample['cleanup_reason'], 'observer-wait-error')
            self.assertFalse(sample['cleanup_confirmed'])
            self.assertFalse(sample['forced_cleanup'])
            self.assertIsNone(sample['exit_status'])
            self.assertIsNone(sample['residual_processes'])
            self.assertTrue(any(error.get('errno') == errno.EPERM for error in sample['cleanup_errors']))
            self.assertEqual(WAITPID(child.pid, os.WNOHANG), (0, 0))
        finally:
            finish_owned(child)
            self.assertTrue(group_absent(child.pid))

    def test_selector_close_error_does_not_erase_real_wait(self):
        for code in (0, 7):
            with self.subTest(exit_code=code):
                selector = runner.selectors.DefaultSelector()
                original_close = selector.close

                def close():
                    original_close()
                    raise OSError(errno.EIO, 'controlled selector close failure')

                with mock.patch.object(selector, 'close', side_effect=close):
                    status, result = self.run_child('raise SystemExit(%d)' % code,
                        lambda: mock.patch.object(runner.selectors, 'DefaultSelector', return_value=selector))
                self.assertEqual(result['wait_status'], code << 8)
                self.assertEqual(result['runner_error'], 'OSError')
                self.assertEqual(status, 125 if code == 0 else 7)
                self.assertFalse(result['timed_out'])

    def test_unknown_query_rejects_success_without_erasing_real_wait(self):
        original_group = runner.process_group
        for code in (0, 7):
            with self.subTest(exit_code=code):
                queries = 0

                def query(*a, **kw):
                    nonlocal queries
                    queries += 1
                    if queries == 1:
                        kw['diagnostic'].update(status='timeout')
                        return None
                    return original_group(*a, **kw)

                status, result = self.run_child('raise SystemExit(%d)' % code,
                    lambda: mock.patch.object(runner, 'process_group', side_effect=query))
                self.assertEqual(result['wait_status'], code << 8)
                self.assertIsNone(result['descendants_at_exit'])
                self.assertEqual(result['process_group_queries']['descendants_at_exit']['status'], 'timeout')
                self.assertEqual(status, 125 if code == 0 else 7)
                self.assertFalse(result['timed_out'])

    def test_observer_cleanup_error_does_not_erase_real_wait(self):
        sample = self.observer_wait_error()
        for code in (0, 7):
            with self.subTest(exit_code=code):
                status, result = self.run_child('raise SystemExit(%d)' % code,
                    lambda: mock.patch.object(runner, 'stop_observers', return_value=[sample]))
                self.assertEqual(result['wait_status'], code << 8)
                self.assertEqual(result['runner_error'], 'ObserverCleanupFailure')
                self.assertEqual(status, 125 if code == 0 else 7)
                self.assertFalse(result['timed_out'])
                self.assertFalse(result['samples'][0]['cleanup_confirmed'])


if __name__ == '__main__':
    unittest.main(argv=[__file__] + remaining, verbosity=2)
