#!/usr/bin/env python3
"""A complete TAP summary and a clean, timely real exit are both required."""
import argparse
import json
from pathlib import Path
import re


def verify(result, text, expected):
    counts = {}
    for key in ('tests', 'pass', 'fail', 'cancelled', 'skipped'):
        values = re.findall(r'^# ' + key + r'\s+(\d+)\s*$', text, re.MULTILINE)
        counts[key] = int(values[0]) if len(values) == 1 else None
    problems = []
    required = dict(exit_kind='exited', exit_code=0, wait_status=0, signal=None, timed_out=False,
                    completed_before_deadline=True, helper_exit_status=0,
                    pipe_eof=True, reader_processes=0, descendants_at_exit=[],
                    residual_processes=[], runner_error=None, signal_errors=[])
    for key, value in required.items():
        if key not in result or result[key] != value:
            problems.append(key)
    if counts != dict(tests=expected, **{'pass': expected}, fail=0, cancelled=0, skipped=0):
        problems.append('incomplete-or-unsuccessful-test-counts')
    return dict(expected=expected, counts=counts, verified=not problems, problems=problems)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--result', type=Path, required=True)
    p.add_argument('--log', type=Path, required=True)
    p.add_argument('--expected', type=int, required=True)
    a = p.parse_args()
    try:
        if a.expected <= 0:
            raise ValueError('invalid-count')
        proof = verify(json.loads(a.result.read_text()), a.log.read_text(), a.expected)
    except (OSError, ValueError, TypeError):
        proof = dict(verified=False, problems=['missing-or-invalid-evidence'])
    (a.result.parent / 'counts.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, sort_keys=True))
    raise SystemExit(0 if proof['verified'] else 1)
