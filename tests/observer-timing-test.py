#!/usr/bin/env python3
"""Deterministic observer bookkeeping tests; no Mac tools or guest execution."""
import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('timed_observer', HERE / 'guest-observer.py')
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)


class Clock:
    def __init__(self, now=10): self.now = now
    def __call__(self): return self.now
    def advance(self, seconds): self.now += seconds


class ToolTimingTests(unittest.TestCase):
    def test_remaining_budget_limits_sample_without_changing_its_three_second_limit(self):
        clock, rows = Clock(), []
        def tool(command, **kwargs):
            self.assertEqual(kwargs['timeout'], 1.25)
            clock.advance(.3)
            return subprocess.CompletedProcess(command, 7, stdout='SYNTHETIC_SECRET', stderr='SYNTHETIC_SECRET')
        with mock.patch.object(observer.time, 'monotonic', clock), \
             mock.patch.object(observer.subprocess, 'run', side_effect=tool):
            completed = observer.run_tool('sample', 'host-all-threads', ['SYNTHETIC_SECRET'],
                observations=rows, limit=3, deadline=11.25, pid=42, capture_output=True)
        self.assertEqual(completed.returncode, 7)
        self.assertEqual(rows[0]['status'], 'nonzero-exit')
        self.assertEqual(rows[0]['limit_seconds'], 3)
        self.assertEqual(rows[0]['remaining_seconds'], 1.25)
        self.assertEqual(rows[0]['allocated_timeout_seconds'], 1.25)
        self.assertEqual(rows[0]['return_code'], 7)
        self.assertAlmostEqual(rows[0]['elapsed_seconds'], .3)
        self.assertAlmostEqual(rows[0]['monotonic_end_seconds'], 10.3)
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(rows))

    def test_expired_budget_does_not_start_tool_and_is_not_an_os_error(self):
        rows = []
        with mock.patch.object(observer.time, 'monotonic', return_value=10), \
             mock.patch.object(observer.subprocess, 'run') as tool:
            with self.assertRaises(observer.ObservationBudgetExhausted):
                observer.run_tool('sample', 'host-all-threads', [], observations=rows, limit=3, deadline=9)
        tool.assert_not_called()
        self.assertEqual(rows[0]['status'], 'budget-exhausted')
        self.assertEqual(rows[0]['allocated_timeout_seconds'], 0)
        self.assertEqual(rows[0]['elapsed_seconds'], 0)
        self.assertNotIn('return_code', rows[0])

    def test_exception_classification_preserves_timing_and_never_exception_text(self):
        cases = [(FileNotFoundError(errno.ENOENT, 'SYNTHETIC_SECRET'), 'tool-unavailable', errno.ENOENT),
                 (PermissionError(errno.EPERM, 'SYNTHETIC_SECRET'), 'permission-denied', errno.EPERM),
                 (OSError(errno.EIO, 'SYNTHETIC_SECRET'), 'os-error', errno.EIO),
                 (subprocess.TimeoutExpired('SYNTHETIC_SECRET', .5,
                                            output='SYNTHETIC_SECRET', stderr='SYNTHETIC_SECRET'), 'timed-out', None)]
        for error, status, expected_errno in cases:
            with self.subTest(status=status):
                clock, rows = Clock(), []
                def tool(command, **kwargs):
                    clock.advance(.5)
                    raise error
                with mock.patch.object(observer.time, 'monotonic', clock), \
                     mock.patch.object(observer.subprocess, 'run', side_effect=tool):
                    with self.assertRaises(type(error)):
                        observer.run_tool('lsof', 'host-descriptors', [], observations=rows, limit=2, deadline=18)
                self.assertEqual(rows[0]['status'], status)
                self.assertEqual(rows[0].get('errno'), expected_errno)
                self.assertEqual(rows[0]['elapsed_seconds'], .5)
                self.assertNotIn('return_code', rows[0])
                self.assertNotIn('SYNTHETIC_SECRET', json.dumps(rows))

    def test_retained_tool_entries_are_bounded(self):
        rows = []
        with mock.patch.object(observer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            for _ in range(100):
                observer.run_tool('ps-identity', 'identity-check', [], observations=rows, limit=1)
        self.assertEqual(len(rows), 64)
        self.assertTrue(all(row['status'] == 'completed' for row in rows))

    def test_unexpected_diagnostic_error_is_preserved_and_cannot_look_still_running(self):
        rows = []
        error = RuntimeError('SYNTHETIC_SECRET')
        with mock.patch.object(observer.subprocess, 'run', side_effect=error):
            with self.assertRaises(RuntimeError) as raised:
                observer.run_tool('ps-tree', 'guest-process-tree', [], observations=rows, limit=2)
        self.assertIs(raised.exception, error)
        self.assertEqual(rows[0]['status'], 'observer-error')
        self.assertNotIn('return_code', rows[0])
        self.assertIn('monotonic_end_seconds', rows[0])
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(rows))

    def test_identity_unknown_is_distinct_from_exhausted_budget(self):
        rows = []
        with mock.patch.object(observer.subprocess, 'run', side_effect=PermissionError(errno.EPERM, 'secret')):
            self.assertIsNone(observer.process_identity(42, rows))
        self.assertEqual(rows[0]['status'], 'permission-denied')
        with mock.patch.object(observer.time, 'monotonic', return_value=10), \
             mock.patch.object(observer.subprocess, 'run') as tool:
            with self.assertRaises(observer.ObservationBudgetExhausted):
                observer.process_identity(42, rows, deadline=9)
        tool.assert_not_called()
        self.assertEqual(rows[-1]['status'], 'budget-exhausted')


class HostObservationTimingTests(unittest.TestCase):
    row = dict(pid=43, ppid=42, pgid=42, state='S', start_identity='42 Fri Oct 16 00:38:36 2026', is_node=True)

    def run_observation(self, mode, *, deadline=18, identity_changes=False, policy='may-exit'):
        clock = Clock()
        def tool(command, **kwargs):
            if command[0] == 'lsof':
                return subprocess.CompletedProcess(command, 0, stdout='p43\nf1\ntPIPE\nSYNTHETIC_SECRET', stderr='')
            self.assertEqual(command[0], '/usr/bin/sample')
            self.assertEqual(command[2:4], ['1', '10'])
            self.assertEqual('-mayDie' in command, policy == 'may-exit')
            self.assertLessEqual(kwargs['timeout'], 3)
            if mode in ('timeout', 'partial-timeout'):
                if mode == 'partial-timeout':
                    Path(command[command.index('-file') + 1]).write_text('SYNTHETIC_SECRET\n + 2 uv_run (in node)\n')
                    kwargs['stdout'].write(b'permission denied SYNTHETIC_SECRET')
                    kwargs['stdout'].flush()
                clock.advance(kwargs['timeout'])
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])
            if mode == 'permission':
                kwargs['stdout'].write(b'permission denied SYNTHETIC_SECRET')
                kwargs['stdout'].flush()
                return subprocess.CompletedProcess(command, 1)
            raw = Path(command[command.index('-file') + 1])
            raw.write_text('SYNTHETIC_SECRET\n' if mode == 'no-frames' else '  + 2 uv_run (in node)\n')
            return subprocess.CompletedProcess(command, 0)
        identities = [self.row['start_identity']] * 3
        if identity_changes: identities[-1] = '999 Fri Oct 16 00:38:36 2026'
        with tempfile.TemporaryDirectory(prefix='dsh-observer-timing-') as private, \
             mock.patch.object(observer.sys, 'platform', 'darwin'), \
             mock.patch.object(observer.time, 'monotonic', clock), \
             mock.patch.object(observer, 'process_identity', side_effect=identities), \
             mock.patch.object(observer.subprocess, 'run', side_effect=tool):
            return observer.observe_host_process(self.row, private, deadline, policy)

    def test_owned_stable_fixture_defers_symbol_lookup_and_keeps_strict_sample_success(self):
        for policy in ('may-exit', 'owned-stable-fixture'):
            with self.subTest(policy=policy):
                result = self.run_observation('frames', policy=policy)
                self.assertEqual(result['sample_policy'], policy)
                self.assertEqual(result['sample_status'], 'completed')
                self.assertEqual(result['sample_exit_status'], 0)
                self.assertTrue(any('function' in frame for frame in result['sample_frames']))
                self.assertEqual(result['tool_observations'][-1]['limit_seconds'], 3)
                self.assertEqual(result['tool_observations'][-1]['allocated_timeout_seconds'], 3)

    def test_partial_frames_and_permission_hint_do_not_turn_timeout_into_success(self):
        result = self.run_observation('partial-timeout', policy='owned-stable-fixture')
        self.assertEqual(result['sample_status'], 'timed-out')
        self.assertEqual(result['tool_observations'][-1]['status'], 'timed-out')
        self.assertEqual(result['sample_timeout_evidence']['report']['function_frame_count'], 1)
        self.assertTrue(result['sample_timeout_evidence']['errors']['permission_hint'])
        self.assertNotIn('sample_frames', result)
        self.assertNotIn('sample_exit_status', result)
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(result))

    def test_invalid_sample_policy_never_starts_tools(self):
        with mock.patch.object(observer.subprocess, 'run') as tool:
            with self.assertRaises(ValueError): observer.observe_host_process(self.row, '/unused', 18, 'unknown')
        tool.assert_not_called()

    def test_partial_evidence_stops_at_budget_and_byte_limits(self):
        with tempfile.TemporaryDirectory() as private:
            path = Path(private) / 'report'
            with mock.patch.object(observer.time, 'monotonic', return_value=10), \
                 mock.patch.object(observer.os, 'open') as opened:
                self.assertEqual(observer.timeout_file_evidence(path, 'report', 9), dict(status='budget-exhausted'))
            opened.assert_not_called()
            self.assertEqual(observer.timeout_file_evidence(path, 'report', time.monotonic() + 8)['status'], 'missing')
            path.write_bytes(b'x' * (64 * 1024 + 100))
            value = observer.timeout_file_evidence(path, 'report', time.monotonic() + 8)
            self.assertEqual(value['status'], 'byte-limit')
            self.assertEqual(value['read_bytes'], 64 * 1024 + 1)
            self.assertNotIn('frame_count', value)

    def test_partial_evidence_discards_work_when_budget_expires_during_stat_read_or_parse(self):
        real_fdopen, real_fstat, real_parse = observer.os.fdopen, observer.os.fstat, observer.parse_sample_frames
        with tempfile.TemporaryDirectory() as private:
            path = Path(private) / 'report'; path.write_text(' + 2 uv_run (in node)\n')
            for stage in ('stat', 'read', 'parse'):
                with self.subTest(stage=stage):
                    clock, reads = Clock(), []
                    class TimedFile:
                        def __init__(self, fd, mode): self.stream = real_fdopen(fd, mode)
                        def __enter__(self): return self
                        def __exit__(self, *args): return self.stream.__exit__(*args)
                        def fileno(self): return self.stream.fileno()
                        def read(self, size):
                            reads.append(size)
                            data = self.stream.read(size)
                            if stage == 'read': clock.advance(9)
                            return data
                    def fstat(fd):
                        info = real_fstat(fd)
                        if stage == 'stat': clock.advance(9)
                        return info
                    def parse(text):
                        frames = real_parse(text)
                        if stage == 'parse': clock.advance(9)
                        return frames
                    with mock.patch.object(observer.time, 'monotonic', clock), \
                         mock.patch.object(observer.os, 'fdopen', side_effect=TimedFile), \
                         mock.patch.object(observer.os, 'fstat', side_effect=fstat), \
                         mock.patch.object(observer, 'parse_sample_frames', side_effect=parse) as parser:
                        result = observer.timeout_file_evidence(path, 'report', 18)
                    self.assertEqual(result['status'], 'budget-exhausted')
                    self.assertNotIn('frame_count', result)
                    self.assertNotIn('function_frame_count', result)
                    if stage == 'stat': self.assertEqual(reads, [])
                    else: self.assertEqual(result['read_bytes'], path.stat().st_size)
                    if stage != 'parse': parser.assert_not_called()

    @unittest.skipUnless(os.name == 'posix', 'requires POSIX process identity and named pipes')
    def test_partial_evidence_refuses_links_and_pipes(self):
        with tempfile.TemporaryDirectory() as private:
            root = Path(private)
            target = root / 'private'; target.write_text('SYNTHETIC_SECRET')
            link = root / 'report'; link.symlink_to(target)
            self.assertEqual(observer.timeout_file_evidence(link, 'report', time.monotonic() + 8)['status'], 'non-regular')
            fifo = root / 'pipe'; os.mkfifo(fifo)
            self.assertEqual(observer.timeout_file_evidence(fifo, 'report', time.monotonic() + 8)['status'], 'non-regular')

    @unittest.skipUnless(os.name == 'posix', 'requires POSIX process identity')
    def test_real_timed_out_tool_is_reaped_before_bounded_partial_evidence(self):
        with tempfile.TemporaryDirectory() as private:
            root = Path(private); report = root / 'report'; pid_file = root / 'pid'
            source = ('import os,time; from pathlib import Path; '
                f'Path({str(pid_file)!r}).write_text(str(os.getpid())); '
                f'Path({str(report)!r}).write_text(" + 2 uv_run (in node)\\n"); time.sleep(10)')
            rows = []
            with self.assertRaises(subprocess.TimeoutExpired):
                observer.run_tool('sample', 'host-all-threads', [sys.executable, '-c', source],
                    observations=rows, limit=.5, deadline=time.monotonic() + 8,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertEqual(rows[0]['status'], 'timed-out')
            self.assertNotIn('return_code', rows[0])
            with self.assertRaises(ProcessLookupError): os.kill(int(pid_file.read_text()), 0)
            value = observer.timeout_file_evidence(report, 'report', time.monotonic() + 8)
            self.assertEqual(value['function_frame_count'], 1)

    def test_matched_identity_does_not_turn_timeout_into_completed_sample(self):
        result = self.run_observation('timeout')
        self.assertEqual(result['identity_status'], 'matched')
        self.assertEqual(result['sample_status'], 'timed-out')
        sample = result['tool_observations'][-1]
        self.assertEqual(sample['status'], 'timed-out')
        self.assertEqual(sample['allocated_timeout_seconds'], 3)
        self.assertEqual(sample['elapsed_seconds'], 3)
        self.assertNotIn('sample_frames', result)
        self.assertNotIn('sample_exit_status', result)

    def test_late_sample_keeps_original_three_second_limit_and_uses_remaining_fraction(self):
        result = self.run_observation('timeout', deadline=10.25)
        sample = result['tool_observations'][-1]
        self.assertEqual(sample['limit_seconds'], 3)
        self.assertEqual(sample['remaining_seconds'], .25)
        self.assertEqual(sample['allocated_timeout_seconds'], .25)
        self.assertEqual(sample['elapsed_seconds'], .25)
        self.assertEqual(result['sample_status'], 'timed-out')

    def test_sample_exit_zero_without_frames_is_still_unsuccessful(self):
        result = self.run_observation('no-frames')
        self.assertEqual(result['sample_status'], 'no-sanitized-frames')
        self.assertEqual(result['sample_exit_status'], 0)
        self.assertEqual(result['tool_observations'][-1]['status'], 'completed')
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(result))

    def test_sample_permission_output_becomes_fixed_status_without_private_text(self):
        result = self.run_observation('permission')
        self.assertEqual(result['sample_status'], 'permission-denied')
        self.assertEqual(result['tool_observations'][-1]['status'], 'permission-denied')
        self.assertEqual(result['tool_observations'][-1]['return_code'], 1)
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(result))

    def test_changed_identity_discards_sample_frames_but_keeps_tool_truth(self):
        result = self.run_observation('frames', identity_changes=True)
        self.assertEqual(result['sample_status'], 'skipped-identity-unconfirmed')
        self.assertEqual(result['identity_status'], 'changed-or-unavailable')
        self.assertEqual(result['tool_observations'][-1]['status'], 'completed')
        self.assertNotIn('sample_frames', result)
        self.assertNotIn('descriptors', result)

    def test_unconfirmed_initial_identity_never_starts_sample(self):
        with mock.patch.object(observer, 'process_identity', return_value=None), \
             mock.patch.object(observer.subprocess, 'run') as tool:
            result = observer.observe_host_process(self.row, '/unused', observer.time.monotonic() + 8)
        tool.assert_not_called()
        self.assertEqual(result['tool_observations'], [])
        self.assertEqual(result['sample_status'], 'skipped-identity-unconfirmed')

    def test_budget_exhausted_between_identity_and_lsof_is_not_an_os_failure(self):
        clock = Clock()
        def identity(*args):
            clock.advance(8.1)
            return self.row['start_identity']
        with mock.patch.object(observer.time, 'monotonic', clock), \
             mock.patch.object(observer, 'process_identity', side_effect=identity), \
             mock.patch.object(observer.subprocess, 'run') as tool:
            result = observer.observe_host_process(self.row, '/unused', 18)
        tool.assert_not_called()
        self.assertEqual(result['descriptor_status'], 'skipped-budget-exhausted')
        self.assertEqual(result['sample_status'], 'skipped-budget-exhausted')
        self.assertEqual(result['tool_observations'][0]['status'], 'budget-exhausted')


class CollectionBudgetTests(unittest.TestCase):
    identity = '42 Fri Oct 16 00:38:36 2026'

    def test_event_collection_does_not_reset_expired_host_budget(self):
        clock = Clock(20)
        with tempfile.TemporaryDirectory(prefix='dsh-observer-budget-') as work, \
             mock.patch.object(observer.time, 'monotonic', clock), \
             mock.patch.object(observer, 'host_events', side_effect=lambda *args: clock.advance(8.1)), \
             mock.patch.object(observer.subprocess, 'run') as tool:
            root = Path(work)
            args = SimpleNamespace(pid=42, phase='job-tracking', output=root / 'out', events=root / 'events',
                                   start_identity=self.identity, host_only=True)
            observer.collect(args)
            result = json.loads((args.output / 'observer.json').read_text())
        tool.assert_not_called()
        self.assertEqual(result['observation_deadline_monotonic_seconds'], 28)
        self.assertEqual(result['process_tree_status'], 'skipped-budget-exhausted')
        self.assertEqual(result['tool_observations'][0]['status'], 'budget-exhausted')
        self.assertAlmostEqual(result['observation_elapsed_seconds'], 8.1)

    def test_host_collection_keeps_eight_second_deadline_and_records_identity_queries(self):
        clock = Clock(20)
        def tool(command, **kwargs):
            clock.advance(.1)
            output = self.identity if command[0] == 'ps' else '42 1 42 S Fri Oct 16 00:38:36 2026 bash\n'
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr='')
        with tempfile.TemporaryDirectory(prefix='dsh-observer-collection-') as work, \
             mock.patch.object(observer.sys, 'platform', 'linux'), \
             mock.patch.object(observer.time, 'monotonic', clock), \
             mock.patch.object(observer.subprocess, 'run', side_effect=tool):
            root = Path(work)
            args = SimpleNamespace(pid=42, phase='job-tracking', output=root / 'out', events=root / 'events',
                                   start_identity=self.identity, host_only=True)
            observer.collect(args)
            result = json.loads((args.output / 'observer.json').read_text())
        self.assertEqual(result['sample_budget_seconds'], 8)
        self.assertEqual(result['observation_deadline_monotonic_seconds'], 28)
        self.assertAlmostEqual(result['observation_elapsed_seconds'], .3)
        self.assertEqual([row['tool'] for row in result['tool_observations']],
                         ['ps-identity', 'ps-group', 'ps-identity'])
        self.assertTrue(all(row['allocated_timeout_seconds'] <= row['remaining_seconds']
                            for row in result['tool_observations']))
        self.assertEqual(result['sample_status'], 'no-node-processes')

    def test_guest_sample_and_lldb_keep_separate_existing_limits_and_record_nonzero(self):
        def tool(command, **kwargs):
            if command[0] == '/usr/bin/sample':
                Path(command[command.index('-file') + 1]).write_text('  + 2 uv_run (in node)\n')
            return subprocess.CompletedProcess(command, 7 if command[0] == 'xcrun' else 0, stdout='', stderr='')
        with tempfile.TemporaryDirectory(prefix='dsh-observer-guest-timing-') as work, \
             mock.patch.object(observer.sys, 'platform', 'darwin'), \
             mock.patch.object(observer, 'process_identity', return_value=self.identity), \
             mock.patch.object(observer.subprocess, 'run', side_effect=tool):
            root = Path(work)
            args = SimpleNamespace(pid=42, phase='selftest', output=root / 'out', events=root / 'events',
                                   start_identity=self.identity, host_only=False)
            observer.collect(args)
            result = json.loads((args.output / 'observer.json').read_text())
        tools = {row['tool']: row for row in result['tool_observations']}
        self.assertEqual(tools['sample']['allocated_timeout_seconds'], 4)
        self.assertEqual(tools['lldb']['allocated_timeout_seconds'], 8)
        self.assertIsNone(tools['sample']['remaining_seconds'])
        self.assertIsNone(tools['lldb']['remaining_seconds'])
        self.assertEqual(tools['lldb']['status'], 'nonzero-exit')
        self.assertEqual(result['lldb_exit_status'], 7)
        self.assertIn('observation_ended_monotonic_seconds', result)

    def test_guest_identity_change_before_lldb_still_finalizes_monotonic_evidence(self):
        def tool(command, **kwargs):
            if command[0] == '/usr/bin/sample':
                Path(command[command.index('-file') + 1]).write_text('  + 2 uv_run (in node)\n')
            self.assertNotEqual(command[0], 'xcrun')
            return subprocess.CompletedProcess(command, 0, stdout='', stderr='')
        with tempfile.TemporaryDirectory(prefix='dsh-observer-identity-timing-') as work, \
             mock.patch.object(observer.sys, 'platform', 'darwin'), \
             mock.patch.object(observer, 'process_identity', side_effect=[self.identity, None]), \
             mock.patch.object(observer.subprocess, 'run', side_effect=tool):
            root = Path(work)
            args = SimpleNamespace(pid=42, phase='selftest', output=root / 'out', events=root / 'events',
                                   start_identity=self.identity, host_only=False)
            observer.collect(args)
            result = json.loads((args.output / 'observer.json').read_text())
        self.assertEqual(result['lldb_error'], 'original-process-ended-before-attach')
        self.assertNotIn('lldb_exit_status', result)
        self.assertIn('observation_ended_monotonic_seconds', result)
        self.assertGreaterEqual(result['observation_elapsed_seconds'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
