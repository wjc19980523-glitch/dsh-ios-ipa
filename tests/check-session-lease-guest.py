#!/usr/bin/env python3
"""Require complete guest assertions and the supervisor's real exit evidence.

Exit 0 means verified; 1 means rejected evidence; 2 means missing/invalid input.
No command, output contents, credentials or filesystem paths are printed.
"""
import argparse
import json
from pathlib import Path
import re
import sys

EXPECTED_TESTS = 18
RECEIPT = f'SESSION_LEASE_GUEST_TESTS {EXPECTED_TESTS}/{EXPECTED_TESTS}; native_flock_executed=true; cycles=100'


def zero(value):
    return type(value) is int and value == 0


def execution_ok(result, phase):
    if not isinstance(result, dict):
        return False
    required = {'phase', 'host_pid', 'wait_status', 'exit_kind', 'exit_code', 'signal',
                'timed_out', 'completed_before_deadline', 'helper_exit_status',
                'reader_processes', 'runner_error', 'descendants_at_exit',
                'residual_processes', 'pipe_eof', 'signal_errors'}
    if not required.issubset(result):
        return False
    return (
        result['phase'] == phase
        and type(result['host_pid']) is int and result['host_pid'] > 0
        and zero(result['wait_status']) and result['exit_kind'] == 'exited'
        and zero(result['exit_code']) and result['signal'] is None
        and result['timed_out'] is False and result['completed_before_deadline'] is True
        and zero(result['helper_exit_status']) and zero(result['reader_processes'])
        and result['runner_error'] is None and result['signal_errors'] == []
        and result['descendants_at_exit'] == [] and result['residual_processes'] == []
        and result['pipe_eof'] is True)


def verify(result, text):
    if not isinstance(text, str) or not execution_ok(result, 'session-lease-native'):
        return False
    lines = text.splitlines()
    passes = [line for line in lines if re.match(r'^\s*PASS\b', line)]
    names = [line.removeprefix('PASS ').strip() for line in passes]
    receipts = [line for line in lines if 'SESSION_LEASE_GUEST_TESTS' in line]
    output_ok = (
        len(passes) == EXPECTED_TESTS and len(set(names)) == EXPECTED_TESTS
        and all(name and line == 'PASS ' + name for line, name in zip(passes, names))
        and receipts == [RECEIPT]
        and all(lines.index(line) < lines.index(RECEIPT) for line in passes)
        and not re.search(
            r'AssertionError|uncaughtException|unhandledRejection|'
            r'^\s*FAIL\b|^\s*(?:[A-Za-z][A-Za-z0-9_.]*Error|Error)(?:\s*\[[^\]\n]+\])?:',
            text, re.M))
    return output_ok


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    try:
        result = json.loads(options.result.read_text(encoding='utf-8'))
        text = options.output.read_text(encoding='utf-8')
    except (OSError, ValueError, UnicodeError) as error:
        print('error: session guest evidence unavailable: ' + type(error).__name__, file=sys.stderr)
        return 2
    if not verify(result, text):
        print('error: real guest session assertions or execution evidence incomplete', file=sys.stderr)
        return 1
    print(f'SESSION_LEASE_GUEST_ASSERTIONS_VERIFIED={EXPECTED_TESTS}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
