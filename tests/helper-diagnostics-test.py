#!/usr/bin/env python3
"""Real unittest cleanup integration and bounded evidence privacy regressions."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('helper_diagnostics', HERE / 'helper-diagnostics.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticTests(unittest.TestCase):
    def export(self, source, destination, **kwargs):
        return diagnostics.export_case(source, destination, '5.3.20', 'Probe.test_case', 1, **kwargs)

    def test_numeric_wait_unknown_and_query_details_survive_without_private_text(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            source = root / 'source'; source.mkdir()
            original = dict(wait_status=0, helper_exit_status=125, descendants_at_exit=None,
                residual_processes=[], timed_out=False, pipe_eof=True,
                process_group_queries=dict(descendants_at_exit=dict(status='malformed-row',
                    malformed_kind='field-count', rows_seen=3, matched_rows=0, private='private-sentinel')),
                command='private-sentinel', stdin='private-sentinel', environment={'TOKEN': 'private-sentinel'},
                runner_error='private-sentinel', host_start_identity='private-sentinel')
            data = json.dumps(original).encode()
            (source / 'result.json').write_bytes(data)
            manifest_path = self.export(source, root / 'output')
            document = json.loads(manifest_path.with_name('result.json').read_text())
            self.assertEqual(document['wait_status'], 0)
            self.assertEqual(document['helper_exit_status'], 125)
            self.assertIsNone(document['descendants_at_exit'])
            self.assertEqual(document['residual_processes'], [])
            self.assertEqual(document['process_group_queries']['descendants_at_exit']['status'], 'malformed-row')
            text = ''.join(p.read_text() for p in manifest_path.parent.iterdir())
            self.assertNotIn('private-sentinel', text)
            record = json.loads(manifest_path.read_text())['source_roles'][0]
            self.assertEqual(record['source_sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(record['exported_sha256'], hashlib.sha256(manifest_path.with_name('result.json').read_bytes()).hexdigest())

    def test_guest_state_has_numeric_locks_but_no_symbol_file_or_variable_text(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / 'guest-state.json').write_text(json.dumps(dict(host_pid=31,
                threads=[dict(host_tid=90, index=1, frames=[dict(function='private-sentinel', file='private-sentinel', pc=44, line=7)],
                    wait_objects=[dict(variable='private-sentinel', address=99, lock=dict(address=8, owner_pthread=90))])],
                lifecycle=dict(active_operations=2, connections=[dict(connection_id=1, cached_autocommit=0,
                    cached_result=5, owner=dict(guest_pid=22, thread_id=90))]),
                errors=['private-sentinel', 'pids-read-failed'])))
            path = self.export(root, root / 'export').with_name('guest-state.json')
            clean = json.loads(path.read_text())
            self.assertEqual(clean['lifecycle']['connections'][0]['cached_autocommit'], 0)
            self.assertEqual(clean['threads'][0]['wait_objects'][0]['lock']['owner_pthread'], 90)
            self.assertNotIn('private-sentinel', path.read_text())

    def test_fixed_tool_timing_fields_survive_and_arbitrary_timing_text_is_dropped(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            row = dict(tool='sample', purpose='host-all-threads', pid=100, limit_seconds=3,
                remaining_seconds=2.5, allocated_timeout_seconds=2.5, monotonic_start_seconds=100.0,
                monotonic_end_seconds=102.6, elapsed_seconds=2.6, status='timed-out',
                return_code=None, private='private-sentinel')
            (root / 'observer.json').write_text(json.dumps(dict(tool_observations=[row],
                host_processes=[dict(pid=100, sample_status='timed-out', tool_observations=[row])],
                sample_frames=[dict(function='private-sentinel')], command='private-sentinel')))
            path = self.export(root, root / 'export').with_name('observer.json')
            clean = json.loads(path.read_text())
            self.assertEqual(clean['tool_observations'][0]['allocated_timeout_seconds'], 2.5)
            self.assertEqual(clean['host_processes'][0]['tool_observations'][0]['status'], 'timed-out')
            self.assertEqual(clean['sanitized_frame_count'], 1)
            self.assertEqual(clean['function_frame_count'], 1)
            self.assertNotIn('private-sentinel', path.read_text())

    def test_size_shape_and_invalid_json_are_reported_without_copying_raw_bytes(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / 'result.json').write_bytes(b'x' * (diagnostics.MAX_SOURCE_BYTES + 1))
            (root / 'observer.json').write_text('not json private-sentinel')
            (root / 'guest-state.json').write_text('[]')
            path = self.export(root, root / 'export')
            statuses = {r['role']: r['status'] for r in json.loads(path.read_text())['source_roles']}
            self.assertEqual(statuses['result'], 'source-byte-limit')
            self.assertEqual(statuses['observer'], 'invalid-json')
            self.assertEqual(statuses['guest-state'], 'invalid-shape')
            self.assertEqual([p.name for p in path.parent.iterdir()], ['manifest.json'])
            self.assertNotIn('private-sentinel', path.read_text())

    def test_list_count_and_run_byte_limits_are_enforced(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            rows = [dict(pid=n, ppid=1, pgid=2, state='R') for n in range(1000)]
            (root / 'result.json').write_text(json.dumps(dict(residual_processes=rows)))
            path = self.export(root, root / 'export')
            self.assertEqual(len(json.loads(path.with_name('result.json').read_text())['residual_processes']), diagnostics.MAX_ROWS)
            self.assertTrue(json.loads(path.read_text())['source_roles'][0]['projection_limited'])
            budget = diagnostics.ExportBudget(); budget.bundles = diagnostics.MAX_BUNDLES
            with self.assertRaisesRegex(RuntimeError, 'diagnostic-count-limit'): self.export(root, root / 'export', budget=budget)
            budget.bundles = 0; budget.bytes = diagnostics.MAX_RUN_BYTES
            with self.assertRaisesRegex(RuntimeError, 'diagnostic-byte-limit'): self.export(root, root / 'export', budget=budget)

    def test_exclusive_destination_preserves_existing_evidence(self):
        with tempfile.TemporaryDirectory() as work, mock.patch.object(diagnostics.uuid, 'uuid4') as unique:
            unique.return_value.hex = 'f' * 32
            root = Path(work)
            (root / 'result.json').write_text('{"wait_status": 1792}')
            path = self.export(root, root / 'export')
            before = path.with_name('result.json').read_bytes()
            (root / 'result.json').write_text('{"wait_status": 0}')
            with self.assertRaises(FileExistsError): self.export(root, root / 'export')
            self.assertEqual(path.with_name('result.json').read_bytes(), before)

    def test_symlink_and_named_pipe_are_not_followed(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / 'private').write_text('{"wait_status": 0}')
            try: (root / 'result.json').symlink_to(root / 'private')
            except OSError: self.skipTest('symlink creation unavailable on this platform')
            if hasattr(diagnostics.os, 'mkfifo'): diagnostics.os.mkfifo(root / 'observer.json')
            path = self.export(root, root / 'export')
            records = {r['role']: r for r in json.loads(path.read_text())['source_roles']}
            self.assertEqual(records['result']['status'], 'non-regular')
            if hasattr(diagnostics.os, 'mkfifo'): self.assertEqual(records['observer']['status'], 'non-regular')

    def test_trusted_root_parent_alias_is_allowed_but_internal_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            real = root / 'real'; real.mkdir()
            fixture = real / 'fixture'; fixture.mkdir()
            (fixture / 'result.json').write_text('{"wait_status": 1792}')
            private = root / 'private'; private.mkdir()
            (private / 'observer.json').write_text('{"host_pid": 123}')
            try:
                (root / 'alias').symlink_to(real, target_is_directory=True)
                (fixture / 'sample').symlink_to(private, target_is_directory=True)
            except OSError: self.skipTest('directory symlink creation unavailable on this platform')
            path = self.export(root / 'alias' / 'fixture', root / 'export')
            records = {row['role']: row for row in json.loads(path.read_text())['source_roles']}
            self.assertEqual(records['result']['status'], 'projected')
            self.assertEqual(json.loads(path.with_name('result.json').read_text())['wait_status'], 1792)
            self.assertEqual(records['sample-observer']['status'], 'non-regular')
            self.assertFalse(path.with_name('sample-observer.json').exists())

    def test_host_runner_initial_and_deadline_observer_roles_are_retained(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            for label in ('initial', '75-seconds'):
                directory = root / label; directory.mkdir()
                (directory / 'observer.json').write_text('{"host_pid": 123, "sample_status": "timed-out"}')
                (directory / 'guest-state.json').write_text('{"lifecycle": {"active_operations": 2}}')
            path = self.export(root, root / 'export')
            records = {row['role']: row for row in json.loads(path.read_text())['source_roles']}
            for label in ('initial', '75-seconds'):
                self.assertEqual(records['host-' + label + '-observer']['status'], 'projected')
                self.assertEqual(records['host-' + label + '-guest-state']['status'], 'projected')
                self.assertEqual(json.loads(path.with_name('host-' + label + '-observer.json').read_text())['sample_status'], 'timed-out')

    @unittest.skipUnless(hasattr(diagnostics.os, 'mkfifo'), 'requires POSIX named pipes')
    def test_regular_file_replaced_by_fifo_before_open_cannot_block_export(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            target = root / 'result.json'; target.write_text('{}')
            real_open = diagnostics.os.open
            def replace(path, flags, *args, **kwargs):
                if Path(path) == target:
                    target.unlink(); diagnostics.os.mkfifo(target)
                    self.assertTrue(flags & diagnostics.os.O_NONBLOCK)
                return real_open(path, flags, *args, **kwargs)
            with mock.patch.object(diagnostics.os, 'open', side_effect=replace):
                path = self.export(root, root / 'export')
            self.assertEqual(json.loads(path.read_text())['source_roles'][0]['status'], 'non-regular')

    def run_probe(self, root, mode, *, export_error=False):
        fixture_names = []
        class Probe(diagnostics.DiagnosticCaseMixin, unittest.TestCase):
            diagnostics_root = root / 'export'
            diagnostics_bash_version = '3.2.57'
            diagnostics_budget = diagnostics.ExportBudget()
            def test_case(self):
                for wait in (0, 1792):
                    with self.temporary_directory(prefix='dsh-retention-test-') as work:
                        fixture_names.append(work)
                        (Path(work) / 'result.json').write_text(json.dumps(dict(wait_status=wait, helper_exit_status=wait >> 8)))
                if mode == 'fail': self.assertEqual(1, 2, 'original-assertion')
                elif mode == 'error': raise RuntimeError('original-exception')
                elif mode == 'subtest':
                    with self.subTest(index=1): self.assertEqual(1, 2, 'original-subtest')
        result = unittest.TestResult()
        if export_error:
            with mock.patch.object(diagnostics, 'export_case', side_effect=OSError('private-sentinel')): Probe('test_case').run(result)
        else: Probe('test_case').run(result)
        self.assertTrue(all(not Path(name).exists() for name in fixture_names))
        return result

    def test_failure_after_helper_return_retains_each_invocation_and_original_failure(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            result = self.run_probe(root, 'fail')
            self.assertEqual(len(result.failures), 1); self.assertEqual(result.errors, [])
            self.assertIn('original-assertion', result.failures[0][1])
            paths = list((root / 'export').rglob('manifest.json'))
            self.assertEqual(len(paths), 2)
            self.assertEqual({json.loads(p.read_text())['invocation'] for p in paths}, {1, 2})
            self.assertEqual({json.loads(p.with_name('result.json').read_text())['wait_status'] for p in paths}, {0, 1792})

    def test_subtest_failure_is_retained(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work); result = self.run_probe(root, 'subtest')
            self.assertEqual(len(result.failures), 1)
            self.assertEqual(len(list((root / 'export').rglob('manifest.json'))), 2)

    def test_test_method_exception_is_retained_without_overwriting_the_error(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work); result = self.run_probe(root, 'error')
            self.assertEqual(result.failures, [])
            self.assertEqual(len(result.errors), 1)
            self.assertIn('original-exception', result.errors[0][1])
            self.assertEqual(len(list((root / 'export').rglob('manifest.json'))), 2)

    def test_success_does_not_export(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work); result = self.run_probe(root, 'success')
            self.assertTrue(result.wasSuccessful())
            self.assertFalse((root / 'export').exists())

    def test_write_failure_cannot_turn_original_assertion_into_a_pass(self):
        with tempfile.TemporaryDirectory() as work:
            result = self.run_probe(Path(work), 'fail', export_error=True)
            self.assertFalse(result.wasSuccessful())
            self.assertEqual(len(result.failures), 1)
            self.assertIn('original-assertion', result.failures[0][1])
            self.assertEqual(len(result.errors), 1)
            self.assertIn('failed-test-diagnostic-export-failed', result.errors[0][1])
            self.assertNotIn('private-sentinel', result.errors[0][1])


if __name__ == '__main__': unittest.main(verbosity=2)
