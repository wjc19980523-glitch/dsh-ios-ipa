#!/usr/bin/env python3
"""Controlled local-only evidence tests; no real guest, Xcode or network."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('job_result', HERE / 'check-job-tracking-result.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
observer_spec = importlib.util.spec_from_file_location('job_observer', HERE / 'guest-observer.py')
observer_module = importlib.util.module_from_spec(observer_spec)
observer_spec.loader.exec_module(observer_module)


def complete_result():
    return dict(exit_kind='exited', exit_code=0, wait_status=0, signal=None, timed_out=False,
                completed_before_deadline=True, helper_exit_status=0,
                pipe_eof=True, reader_processes=0, descendants_at_exit=[],
                residual_processes=[], runner_error=None, signal_errors=[])


PASS = '# tests 1\n# pass 1\n# fail 0\n# cancelled 0\n# skipped 0\n'


def trace_rows(base):
    """Validate every complete producer file, rather than hiding malformed lines."""
    rows = []
    for path in [base, *sorted(base.parent.glob(base.name + '.*.jsonl'))]:
        if not path.is_file():
            continue
        shard_pid = int(path.name[len(base.name) + 1:-6]) if path != base else None
        for line in path.read_text().splitlines():
            row = json.loads(line)
            if shard_pid is not None and row['pid'] != shard_pid:
                raise AssertionError('trace shard PID mismatch')
            rows.append(row)
    return rows


class CountEvidenceTests(unittest.TestCase):
    def test_complete_clean_exit_passes(self):
        self.assertTrue(checker.verify(complete_result(), PASS, 1)['verified'])

    def test_pass_text_then_timeout_cannot_pass(self):
        result = complete_result()
        result.update(timed_out=True, completed_before_deadline=False)
        self.assertFalse(checker.verify(result, PASS, 1)['verified'])
    def test_nonzero_exit_cannot_be_hidden_by_summary(self):
        result = complete_result()
        result.update(exit_code=7, helper_exit_status=7)
        self.assertFalse(checker.verify(result, PASS, 1)['verified'])

    def test_partial_duplicate_failed_skipped_or_wrong_count_cannot_pass(self):
        for text, expected in [('', 1), (PASS + PASS, 1), (PASS, 2),
                               (PASS.replace('# fail 0', '# fail 1'), 1),
                               (PASS.replace('# skipped 0', '# skipped 1'), 1)]:
            with self.subTest(text=text, expected=expected):
                self.assertFalse(checker.verify(complete_result(), text, expected)['verified'])

    def test_missing_wait_status_or_residual_reader_cannot_pass(self):
        for change in [dict(exit_kind='unknown', exit_code=None),
                       dict(residual_processes=[dict(pid=1)]), dict(reader_processes=1),
                       dict(pipe_eof=False), dict(runner_error='SyntheticFailure')]:
            with self.subTest(change=change):
                result = complete_result(); result.update(change)
                self.assertFalse(checker.verify(result, PASS, 1)['verified'])
        result = complete_result(); del result['wait_status']
        self.assertFalse(checker.verify(result, PASS, 1)['verified'])


class DiagnosticPrivacyTests(unittest.TestCase):
    def test_host_phase_observations_drop_unknown_fields_and_free_text(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(prefix='dsh-job-privacy-') as work:
            path = Path(work) / 'phases.jsonl'
            valid = dict(schema=1, phase='job-tracking', fileTag='runner', event='bootstrap', pid=42,
                         ppid=8, monotonic_ns='123', node_version='v22.1.0', token='SYNTHETIC_SECRET')
            invalid = dict(valid, event='SYNTHETIC_SECRET')
            path.write_text(json.dumps(valid) + '\n' + json.dumps(invalid) + '\n')
            result = {}
            observer_module.host_events(SimpleNamespace(events=path, phase='job-tracking'), result)
            self.assertEqual(len(result['service_events']), 1)
            self.assertNotIn('SYNTHETIC_SECRET', json.dumps(result))
            self.assertNotIn('token', result['service_events'][0])

    def test_sample_filter_retains_frames_without_headers_paths_or_addresses(self):
        with tempfile.TemporaryDirectory(prefix='dsh-job-sample-') as work:
            raw = Path(work) / 'sample.txt'
            raw.write_text('Authorization: SYNTHETIC_SECRET\n  1 Thread_9\n  + 2 uv_run (in node) (0x123 /private/SYNTHETIC_SECRET)\n')
            frames = observer_module.sample_frames(raw)
            self.assertTrue(any(frame.get('function') == 'uv_run' for frame in frames))
            self.assertNotIn('SYNTHETIC_SECRET', json.dumps(frames))
            self.assertNotIn('0x123', json.dumps(frames))

    def test_host_phase_reader_aggregates_pid_shards_and_reports_corruption(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(prefix='dsh-job-shards-') as work:
            path = Path(work) / 'phases.jsonl'
            shell = dict(schema=1, phase='job-tracking', fileTag='shell', event='suite:start', pid=42)
            worker = dict(schema=1, phase='job-tracking', fileTag='runner', event='bootstrap', pid=43)
            path.write_text(json.dumps(shell) + '\n')
            shard = Path(str(path) + '.43.jsonl')
            shard.write_text(json.dumps(worker) + '\n')
            result = {}
            args = SimpleNamespace(events=path, phase='job-tracking')
            observer_module.host_events(args, result)
            self.assertEqual(result['service_events_status'], 'completed', result)
            self.assertEqual({row['pid'] for row in result['service_events']}, {42, 43})
            shard.write_text(json.dumps(dict(worker, pid=44)) + '\nnot-json\n')
            result = {}; observer_module.host_events(args, result)
            self.assertEqual(result['service_events_status'], 'incomplete', result)
            self.assertIn('malformed-json', result['service_events_issues'])
            self.assertIn('shard-pid-mismatch', result['service_events_issues'])
            self.assertEqual(result['service_events'], [shell])


class HostProcessTableTests(unittest.TestCase):
    def parse_darwin(self, names):
        table = '\n'.join(f'{800 + i} 799 800 S Fri Oct 16 00:38:36 2026 ' + name.ljust(16)
                          for i, name in enumerate(names)) + '\n'
        completed = subprocess.CompletedProcess([], 0, stdout=table, stderr='')
        with mock.patch.object(observer_module.sys, 'platform', 'darwin'), \
             mock.patch.object(observer_module.subprocess, 'run', return_value=completed) as query:
            rows, non_nodes, skipped = observer_module.host_processes(800)
        self.assertEqual(query.call_args.args[0],
            ['/bin/ps', '-g', '800', '-o', 'pid=,ppid=,pgid=,stat=,lstart=,ucomm='])
        return rows, non_nodes, skipped

    def test_darwin_padded_last_column_recognizes_only_exact_node_basenames(self):
        rows, non_nodes, skipped = self.parse_darwin(['bash', 'node', 'nodejs'])
        self.assertEqual([row['pid'] for row in rows if row['is_node']], [801, 802])
        self.assertEqual(non_nodes, 1)
        self.assertEqual(skipped, [])
        self.assertTrue(all(row['pgid'] == 800 and row['start_identity'].startswith('800 ') for row in rows))
        self.assertTrue(all('ucomm' not in row and 'command' not in row for row in rows))

    def test_darwin_padding_does_not_admit_node_like_names_or_leave_group(self):
        rows, non_nodes, skipped = self.parse_darwin(['node-helper', 'notnode', 'nodejs-helper'])
        self.assertFalse(any(row['is_node'] for row in rows))
        self.assertEqual(non_nodes, 3)
        self.assertEqual(skipped, [])
        self.assertNotIn('node-helper', json.dumps(rows))
        outside = '900 799 900 S Fri Oct 16 00:38:36 2026 node            \n'
        completed = subprocess.CompletedProcess([], 0, stdout=outside, stderr='')
        with mock.patch.object(observer_module.sys, 'platform', 'darwin'), \
             mock.patch.object(observer_module.subprocess, 'run', return_value=completed):
            rows, non_nodes, skipped = observer_module.host_processes(800)
        self.assertEqual(rows, [])
        self.assertEqual(skipped, [dict(pid=900, reason='left-supervised-group')])

    def test_changed_process_identity_never_collects_descriptors_or_samples(self):
        import time
        row = dict(pid=801, ppid=800, pgid=800, state='S',
                   start_identity='800 Fri Oct 16 00:38:36 2026', is_node=True)
        for identity in ('800 Fri Oct 16 00:38:37 2026', '900 Fri Oct 16 00:38:36 2026'):
            with self.subTest(identity=identity), \
                 mock.patch.object(observer_module, 'process_identity', return_value=identity) as check, \
                 mock.patch.object(observer_module.subprocess, 'run') as collect:
                result = observer_module.observe_host_process(row, '/unused', time.monotonic() + 1)
            check.assert_called_once_with(801)
            collect.assert_not_called()
            self.assertEqual(result['identity_status'], 'changed-or-unavailable')
            self.assertEqual(result['sample_status'], 'skipped-identity-unconfirmed')
            self.assertNotIn('descriptors', result)
            self.assertNotIn('sample_frames', result)


class OwnedProcessTests(unittest.TestCase):
    def probe(self, source, *, timeout=2, sample_after=0, test=False, trace=True):
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node is required; this evidence test must really run')
        with tempfile.TemporaryDirectory(prefix='dsh-job-supervision-') as work:
            root = Path(work)
            script = root / 'fixture.mjs'; script.write_text(source)
            result = root / 'result.json'; events = root / 'phases.jsonl'; events.write_text('')
            environment = os.environ.copy()
            if trace: environment['DSH_JOB_TRACE_FILE'] = str(events)
            else: environment.pop('DSH_JOB_TRACE_FILE', None)
            command = [node]
            if trace: command += ['--import', str(HERE / 'job-tracking-trace.mjs')]
            if test: command += ['--test', '--test-reporter=tap']
            command.append(str(script))
            process = subprocess.run([sys.executable, str(HERE / 'guest-runner.py'), 'run',
                '--host-only', '--phase', 'job-tracking', '--result', str(result), '--events', str(events),
                '--timeout', str(timeout), '--sample-after', str(sample_after), '--', *command],
                env=environment, capture_output=True, text=True, timeout=10)
            proof = json.loads(result.read_text())
            rows = trace_rows(events)
            observer_path = root / '75-seconds/observer.json'
            observer = json.loads(observer_path.read_text()) if observer_path.exists() else None
            self.assertTrue(proof['pipe_eof'])
            self.assertEqual(proof['reader_processes'], 0)
            self.assertEqual(proof['residual_processes'], [])
            return process, proof, rows, observer

    def test_real_node_test_passes_with_trace_and_complete_counts(self):
        process, proof, rows, _ = self.probe("import test from 'node:test'; test('controlled pass', () => {});", test=True)
        self.assertEqual(process.returncode, 0, process.stdout)
        self.assertTrue(checker.verify(proof, process.stdout, 1)['verified'])
        self.assertTrue(any(row['event'] == 'bootstrap' for row in rows))
        self.assertTrue(any(row['event'] == 'exit' for row in rows))

    def test_real_node_failure_preserves_nonzero_status(self):
        process, proof, _, _ = self.probe("import test from 'node:test'; test('controlled fail', () => { throw Error('controlled'); });", test=True)
        self.assertEqual(process.returncode, 1)
        self.assertEqual(proof['exit_code'], 1)
        self.assertFalse(checker.verify(proof, process.stdout, 1)['verified'])

    def test_real_pass_text_then_timeout_fails_and_reaps_group(self):
        source = 'console.log(' + json.dumps('unauthorized\n' + PASS) + '); setInterval(() => {}, 1000);'
        process, proof, _, _ = self.probe(source, timeout=.35)
        self.assertEqual(process.returncode, 142)
        self.assertTrue(proof['timed_out'])
        self.assertEqual(proof['wait_status'], 14)
        self.assertEqual(proof['timeout_kind'], 'business-output-then-timeout')
        self.assertFalse(checker.verify(proof, process.stdout, 1)['verified'])

    def test_real_pure_timeout_has_no_business_output(self):
        process, proof, _, _ = self.probe('setInterval(() => {}, 1000);', timeout=.35)
        self.assertEqual(process.returncode, 142)
        self.assertFalse(proof['business_output'])
        self.assertEqual(proof['timeout_kind'], 'no-business-output-timeout')

    def test_host_observer_is_bounded_and_never_invokes_guest_lldb(self):
        process, proof, rows, observer = self.probe('setInterval(() => {}, 1000);', timeout=1, sample_after=.2)
        self.assertEqual(process.returncode, 142)
        self.assertEqual(len(proof['samples']), 1)
        self.assertIsNotNone(observer)
        self.assertEqual(observer['mode'], 'host-only')
        self.assertEqual(proof['samples'][0]['exit_status'], 0)
        self.assertEqual(observer['process_tree_status'], 'completed', observer)
        self.assertTrue(any(row['pid'] == proof['host_pid'] for row in observer['process_tree']))
        self.assertTrue(observer['host_processes'], observer)
        self.assertTrue(any(row['pid'] == proof['host_pid'] and row['identity_status'] in ('matched', 'changed-or-unavailable')
                            for row in observer['host_processes']))
        self.assertNotIn('lldb_exit_status', observer)
        if sys.platform != 'darwin':
            # This negative run may end while observation is in progress. Such
            # a skip must be explicit; it cannot claim a completed Linux sample.
            self.assertTrue(all(row.get('sample_status') in ('macOS-only',
                'skipped-identity-unconfirmed', 'skipped-budget-exhausted') for row in observer['host_processes']))

    def test_host_observer_keeps_bash_parent_and_samples_only_owned_node(self):
        from types import SimpleNamespace
        node = shutil.which('node'); self.assertIsNotNone(node)
        with tempfile.TemporaryDirectory(prefix='dsh-job-tree-') as work:
            root = Path(work); events = root / 'events.jsonl'; events.write_text('')
            child = subprocess.Popen(['/bin/bash', '-c',
                '"$@" & child=$!; trap \'kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; exit 0\' TERM; wait "$child"',
                'bash', node, '-e', 'setInterval(() => {}, 1000);'],
                start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                import time
                time.sleep(.1)
                observer_module.collect(SimpleNamespace(pid=child.pid, phase='job-tracking',
                    output=root / 'sample', events=events, host_only=True,
                    start_identity=observer_module.process_identity(child.pid)))
                proof = json.loads((root / 'sample/observer.json').read_text())
                self.assertEqual(proof['process_tree_status'], 'completed', proof)
                self.assertTrue(any(row['pid'] == child.pid for row in proof['process_tree']))
                self.assertTrue(any(row['pid'] != child.pid and row['ppid'] == child.pid for row in proof['process_tree']))
                self.assertTrue(proof['host_processes'], proof)
                self.assertTrue(all(row['pid'] != child.pid and row['pgid'] == child.pid for row in proof['host_processes']))
                self.assertTrue(all(row['identity_status'] == 'matched' for row in proof['host_processes']))
                if sys.platform != 'darwin':
                    self.assertTrue(all(row['sample_status'] == 'macOS-only' for row in proof['host_processes']))
            finally:
                try: os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=2)

    def test_tracing_does_not_turn_original_nonzero_exit_into_success(self):
        process, proof, rows, _ = self.probe('process.exitCode = 7;')
        self.assertEqual(process.returncode, 7)
        self.assertEqual(proof['exit_code'], 7)

    def test_trace_write_failure_is_nonzero_and_preserves_an_existing_nonzero(self):
        for original, expected in [(0, 1), (7, 7)]:
            with self.subTest(original=original):
                source = "import fs from 'node:fs'; const path = process.env.DSH_JOB_TRACE_FILE + '.' + process.pid + '.jsonl'; fs.unlinkSync(path); fs.mkdirSync(path); process.exitCode = " + str(original) + ';'
                process, proof, _, _ = self.probe(source)
                self.assertEqual(process.returncode, expected, process.stdout)
                self.assertEqual(proof['exit_code'], expected)
                self.assertIn('DSH_JOB_TRACE_WRITE_FAILED', process.stdout)

    def test_trace_rejects_free_text_without_persisting_it(self):
        module = json.dumps((HERE / 'job-tracking-trace.mjs').as_uri())
        source = "const { traceStage } = await import(" + module + "); traceStage('runner', 'SYNTHETIC_UNSAFE_TEXT');"
        process, proof, rows, _ = self.probe(source)
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn('SYNTHETIC_UNSAFE_TEXT', json.dumps(rows))

    def test_trace_preserves_a_synchronous_test_callback(self):
        module = json.dumps((HERE / 'job-tracking-trace.mjs').as_uri())
        source = "import assert from 'node:assert/strict'; const { createTracedTest } = await import(" + module + "); const after=[]; const stub=(_name, callback)=>callback({after: f=>after.push(f)}); const traced=createTracedTest(stub, 'job-ledger-test'); assert.equal(traced('controlled', ()=>7), 7); for (const f of after) f();"
        process, proof, rows, _ = self.probe(source)
        self.assertEqual(process.returncode, 0, process.stdout)
        self.assertTrue(any(row['event'] == 'body:done' for row in rows))
        self.assertTrue(any(row['event'] == 'after:last' for row in rows))

    def test_concurrent_producers_keep_complete_pid_shards_on_workspace_filesystem(self):
        # /tmp alone misses the reproduced WSL /mnt/d shared-append corruption.
        node = shutil.which('node'); self.assertIsNotNone(node)
        diagnostics = HERE.parent / 'cilogs-verify'; diagnostics.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='trace-integrity.', dir=diagnostics) as work:
            root = Path(work); events = root / 'phases.jsonl'; barrier = root / 'ready'
            shell = dict(schema=1, phase='job-tracking', fileTag='shell', event='suite:start', pid=os.getpid())
            events.write_text(json.dumps(shell) + '\n')
            module = json.dumps((HERE / 'job-tracking-trace.mjs').as_uri())
            source = ("import fs from 'node:fs'; const { traceStage } = await import(" + module + "); "
                      "while (!fs.existsSync(process.argv[1])) await new Promise(r => setTimeout(r, 2)); "
                      "for (let i = 0; i < 64; i++) traceStage('job-ledger-test', 'body:start');")
            environment = os.environ.copy(); environment['DSH_JOB_TRACE_FILE'] = str(events)
            children = []
            try:
                for _ in range(8):
                    children.append(subprocess.Popen([node, '--input-type=module', '-e', source, str(barrier)],
                        env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
                barrier.write_text('ready')
                for child in children:
                    stdout, stderr = child.communicate(timeout=8)
                    self.assertEqual(child.returncode, 0, stdout + stderr)
                shards = list(root.glob('phases.jsonl.*.jsonl'))
                self.assertEqual(len(shards), 8)
                rows = trace_rows(events)
                self.assertEqual(json.loads(events.read_text()), shell)
                self.assertEqual(len(rows), 1 + 8 * (64 + 3))
                for child in children:
                    owned = [row for row in rows if row['pid'] == child.pid]
                    self.assertEqual(sum(row['event'] == 'body:start' for row in owned), 64)
                    for event in ('bootstrap', 'beforeExit', 'exit'):
                        self.assertEqual(sum(row['event'] == event for row in owned), 1)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=3)

    def test_wrapper_preserves_primary_failure_when_tee_also_fails(self):
        # Negative infrastructure fixture, not a substitute for real Node tests.
        with tempfile.TemporaryDirectory(prefix='dsh-job-pipeline-') as work:
            root = Path(work); scripts = root / 'tests'; scripts.mkdir()
            for name in ('job-tracking-test.sh', 'guest-runner.py', 'guest-observer.py',
                         'check-job-tracking-result.py', 'job-tracking-trace.mjs'):
                shutil.copyfile(HERE / name, scripts / name)
            (scripts / 'job-tracking-prepare.py').write_text("from pathlib import Path\nimport sys\n(Path(sys.argv[2]) / 'bridge-patched.mjs').write_text('')\n")
            tools = root / 'tools'; tools.mkdir()
            (tools / 'node').write_text('#!/bin/sh\nif [ "$1" = "--check" ]; then exit 0; fi\nprintf "# tests 60\\n# pass 60\\n# fail 0\\n# cancelled 0\\n# skipped 0\\n"\nexit 7\n')
            (tools / 'tee').write_text('#!/bin/sh\ncat >/dev/null\nexit 3\n')
            for name in ('node', 'tee'): (tools / name).chmod(0o700)
            environment = os.environ.copy(); environment['PATH'] = str(tools) + os.pathsep + environment['PATH']
            process = subprocess.run(['/bin/bash', str(scripts / 'job-tracking-test.sh')],
                                     env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 7, process.stdout)
            results = list(root.glob('cilogs-verify/job-tracking.*/result.json'))
            self.assertEqual(len(results), 1)
            proof = json.loads(results[0].read_text())
            self.assertEqual(proof['wait_status'], 7 << 8)
            self.assertEqual(proof['helper_exit_status'], 7)
            self.assertFalse(proof['timed_out'])
            self.assertEqual(proof['residual_processes'], [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
