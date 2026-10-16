#!/usr/bin/env python3
"""Independent real-Node/packed-SDK cleanup controls; never part of the 60-case TAP."""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CHILD_DEADLINE_SECONDS = 5


def utc():
    return datetime.now(timezone.utc).isoformat()


def rows(path):
    if not path.exists():
        return []
    text = path.read_text(encoding='utf-8')
    lines = text.splitlines()
    if text and not text.endswith('\n'):
        lines = lines[:-1]  # The producer may currently be inside its synchronous append.
    return [json.loads(line) for line in lines if line.strip()]


def stop_owned(process):
    if process.poll() is not None:
        return
    try:
        if os.name == 'posix':
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            if os.name == 'posix':
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.wait(timeout=1)


def run_case(node, fixtures, diagnostics, mode):
    casework = Path(tempfile.mkdtemp(prefix='dsh-cleanup-case-'))
    proof, execution_log = casework / 'proof.jsonl', casework / 'child.log'
    saved_proof, log = diagnostics / f'{mode}.jsonl', diagnostics / f'{mode}.log'
    proof.write_text('', encoding='utf-8')
    command = [node, '--test-reporter=tap', str(HERE / 'job-tracking-cleanup-probe.mjs'), mode, str(fixtures), str(proof)]
    started, monotonic = utc(), time.monotonic()
    observed_live = False
    result = dict(mode=mode, command=command, started_utc=started, deadline_seconds=CHILD_DEADLINE_SECONDS,
                  timed_out=False, stopped_after_negative_proof=False, log=str(log), proof=str(saved_proof))
    pending_error = None
    with execution_log.open('wb') as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=os.name == 'posix')
        result['pid'] = process.pid
        try:
            while process.poll() is None:
                current = rows(proof)
                observation = next((row for row in current if row['event'] == 'post-hooks'), None)
                if mode == 'old-short-circuit' and observation:
                    assert observation['server_listening'] and not observation['environment_restored']
                    failure = next(row for row in current if row['event'] == 'cleanup:error')
                    assert failure['same_error'] and failure['code'] == 'E_CONTROLLED_RM'
                    assert not any(row['event'] in ('old:server-close', 'old:env-restore') for row in current)
                    body = next(row for row in current if row['event'] == 'body:done')
                    connection = http.client.HTTPConnection('127.0.0.1', body['port'], timeout=1)
                    try:
                        connection.request('GET', '/proof')
                        response = connection.getresponse()
                        assert response.status == 200 and json.loads(response.read()) == {'controlled': True}
                    finally:
                        connection.close()
                    observed_live = True
                    result['stopped_after_negative_proof'] = True
                    stop_owned(process)
                    break
                if time.monotonic() - monotonic >= CHILD_DEADLINE_SECONDS:
                    result['timed_out'] = True
                    raise AssertionError('cleanup child exceeded its independent deadline')
                time.sleep(0.02)
        except Exception as error:
            pending_error = error
        finally:
            cleanup_errors = []
            try: stop_owned(process)
            except Exception as error: cleanup_errors.append(type(error).__name__)
            residual = None
            if os.name == 'posix' and process.poll() is not None:
                try: os.killpg(process.pid, 0)
                except ProcessLookupError: residual = []
                except PermissionError: cleanup_errors.append('group_query_unconfirmed')
                else: residual = [dict(pgid=process.pid)]
            result.update(exit_code=process.returncode, finished_utc=utc(), elapsed_seconds=time.monotonic()-monotonic,
                          child_reaped=process.poll() is not None, residual_processes=residual, cleanup_errors=cleanup_errors,
                          residual_scope='owned process group query after reap' if os.name == 'posix' else 'owned Node PID reaped only; Windows whole-tree absence not verified')
    # Live polling stays on the native temporary filesystem; archive complete
    # bytes afterwards, avoiding append/read races on WSL's mounted workspace.
    log.write_bytes(execution_log.read_bytes())
    saved_proof.write_bytes(proof.read_bytes())
    shutil.rmtree(casework)
    result['log_sha256'] = hashlib.sha256(log.read_bytes()).hexdigest()
    result['proof_sha256'] = hashlib.sha256(saved_proof.read_bytes()).hexdigest()
    (diagnostics / f'{mode}.result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    if pending_error is not None:
        raise pending_error
    assert result['child_reaped'] and not result['cleanup_errors']
    if os.name == 'posix':
        assert result['residual_processes'] == []
    current = rows(saved_proof)
    assert all(row['pid'] == process.pid for row in current)
    bootstrap = next(row for row in current if row['event'] == 'bootstrap')
    result['node_version'], result['node_platform'] = bootstrap['node_version'], bootstrap['platform']
    observation = next(row for row in current if row['event'] == 'post-hooks')
    if mode == 'old-short-circuit':
        assert observed_live and not result['timed_out']
        result['verified'] = 'old hook short-circuit and live HTTP listener observed; owned child explicitly stopped, not a timeout pass'
    else:
        expected = 0 if mode == 'clean' else 1
        assert process.returncode == expected and not result['timed_out']
        assert not observation['server_listening'] and observation['environment_restored']
        assert observation['bridge_flushed'] and observation['removed_record_saved']
        if mode != 'clean':
            failure = next(row for row in current if row['event'] == 'cleanup:error')
            expected_code = 'E_CONTROLLED_JOBS' if mode == 'early-error' else 'E_CONTROLLED_RM'
            assert failure['same_error'] and failure['code'] == expected_code
        if mode in ('multiple-errors', 'early-error'):
            assert any(row['event'] == 'bridge:server.close:error' for row in current)
            assert any(row['event'] == 'bridge:env.restore:error' for row in current)
        text = log.read_text(encoding='utf-8')
        assert text.count('# tests 1\n') == 1 and text.count('# fail '+str(expected)+'\n') == 1
        result['verified'] = 'normal bounded exit with actual bridge journal drained and server/environment released'
    (diagnostics / f'{mode}.result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--diagnostics', type=Path)
    parser.add_argument('--node', default=shutil.which('node'))
    args = parser.parse_args()
    assert args.node, 'existing Node is required; this test installs nothing'
    (ROOT / 'cilogs-verify').mkdir(exist_ok=True)
    diagnostics = args.diagnostics or Path(tempfile.mkdtemp(prefix='job-tracking-cleanup.', dir=ROOT / 'cilogs-verify'))
    diagnostics.mkdir(parents=True, exist_ok=True)
    report = dict(started_utc=utc(), cases=[], source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (HERE/'job-tracking-cleanup.mjs', HERE/'job-tracking-cleanup-probe.mjs', Path(__file__), HERE/'job-tracking-runtime-test.mjs')})
    try:
        with tempfile.TemporaryDirectory(prefix='dsh-job-cleanup-sdk-') as temporary:
            fixtures = args.fixtures.resolve() if args.fixtures else Path(temporary) / 'fixtures'
            if not args.fixtures:
                command = [sys.executable, str(HERE/'job-tracking-prepare.py'), '--fixtures', str(fixtures)]
                started = utc()
                with (diagnostics/'prepare.log').open('wb') as output:
                    prepared = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=30)
                report['prepare'] = dict(command=command, started_utc=started, finished_utc=utc(), exit_code=prepared.returncode)
                assert prepared.returncode == 0
            report['packed_source_hashes'] = {str(p.relative_to(fixtures)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                (fixtures/'bridge-patched.mjs',fixtures/'job-tracking.mjs',fixtures/'job-ledger.mjs',
                 fixtures/'node_modules/@deepseek-ai/cordis/lib/index.js',fixtures/'node_modules/@deepseek-ai/dsh-jobs-local/lib/index.js')}
            for mode in ('old-short-circuit', 'clean', 'rm-error', 'multiple-errors', 'early-error'):
                report['cases'].append(run_case(args.node, fixtures, diagnostics, mode))
        report['verified'] = True
    except Exception as error:
        report.update(verified=False, error_type=type(error).__name__, error=str(error))
    report['finished_utc'] = utc()
    (diagnostics/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(verified=report['verified'], cases=len(report['cases']), diagnostics=str(diagnostics))))
    return 0 if report['verified'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
