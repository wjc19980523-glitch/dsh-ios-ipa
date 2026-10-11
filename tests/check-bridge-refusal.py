#!/usr/bin/env python3
"""Require actual HTTP401, expected tool result, timely exit, and complete cleanup."""
import argparse
import json
from pathlib import Path


def verify(result, output, events):
    checks = {
        'normal_exit_zero': result['exit_kind'] == 'exited' and result['exit_code'] == 0,
        'within_deadline': not result['timed_out'] and result['completed_before_deadline'],
        'clean_process_group': result['residual_processes'] == [] and result['descendants_at_exit'] == [],
        'pipe_eof': result['pipe_eof'] and result['reader_processes'] == 0,
        'helper_success': result['helper_exit_status'] == 0,
        'expected_tool_refusal': 'TOOL-RESULT-BEGIN Error: missing or wrong bridge token [unauthorized] TOOL-RESULT-END' in output,
    }
    rows = [r for r in events if r.get('phase') == 'wrong-token']
    received = {r['request_id']: r for r in rows if r.get('service') == 'bridge' and r.get('kind') == 'request'}
    checks['bridge_received_expected_route'] = any(r.get('route') == '/v1/shortcut/run' and r.get('method') == 'POST' for r in received.values())
    checks['bridge_finished_401'] = any(r.get('kind') == 'response_finished' and r.get('service') == 'bridge'
        and r.get('request_id') in received and received[r['request_id']].get('route') == '/v1/shortcut/run'
        and r.get('status') == 401 and r.get('unauthorized') is True for r in rows)
    checks['mock_received_request'] = any(r.get('service') == 'mock' and r.get('kind') == 'request' for r in rows)
    checks['mock_received_refusal'] = any(r.get('service') == 'mock' and r.get('kind') == 'tool_result' and r.get('unauthorized') is True for r in rows)
    return checks


def main():
    p = argparse.ArgumentParser()
    for name in ('result', 'output', 'events'): p.add_argument('--' + name, required=True, type=Path)
    a = p.parse_args()
    try:
        checks = verify(json.loads(a.result.read_text()), a.output.read_text(),
                        [json.loads(s) for s in a.events.read_text().splitlines() if s.strip()])
    except (OSError, ValueError, KeyError) as e:
        print('wrong-token evidence unavailable:', type(e).__name__)
        return 1
    print('wrong-token assertions:', json.dumps(checks, sort_keys=True))
    return 0 if all(checks.values()) else 1


if __name__ == '__main__': raise SystemExit(main())
