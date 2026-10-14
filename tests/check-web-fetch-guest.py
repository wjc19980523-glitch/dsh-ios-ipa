#!/usr/bin/env python3
"""Require real wait/timeout/pipe cleanup AND every unique transport test receipt."""
import argparse
import json
from pathlib import Path
import re

EXPECTED = 47


def check(result, output):
    assert result['phase'] == 'web-fetch-native', 'wrong guest execution phase'
    assert type(result['host_pid']) is int and result['host_pid'] > 0, 'missing host PID'
    assert result['timed_out'] is False, 'guest exceeded original 90-second deadline'
    assert result['exit_kind'] == 'exited', 'guest did not exit normally'
    for key in ['wait_status', 'exit_code', 'helper_exit_status', 'reader_processes']:
        assert type(result[key]) is int and result[key] == 0, f'guest {key} failed'
    assert result['signal'] is None and result['signal_errors'] == [], 'guest was signaled or cleanup failed'
    assert result['completed_before_deadline'] is True, 'guest did not finish before deadline'
    assert result['runner_error'] is None, 'guest runner failed'
    assert result['pipe_eof'] is True, 'output pipe has no EOF'
    assert result['descendants_at_exit'] == [] and result['residual_processes'] == [], 'residual process group'
    assert result['elapsed_seconds'] < 90, 'guest completed beyond test deadline'
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output).replace('\r\n', '\n')
    passed = re.findall(r'^PASS (.+)$', text, re.M)
    assert len(passed) == EXPECTED and len(set(passed)) == EXPECTED, f'expected {EXPECTED} unique test passes, got {len(passed)}'
    assert all(name in passed for name in [
        'ARM original packaged provider reproduces incompatible parser failure',
        'ARM complete patched package reads HTTPS and same-origin redirect',
        'ARM complete package rejects private destination without fixture resolver',
        'ARM complete package obeys installed proxy policy without origin DNS',
        'ARM complete provider emits private metadata only after reading the body',
        'ARM complete provider classifies policy DNS and timeout failures privately',
        'ARM complete provider preserves outcomes when diagnostic stderr fails',
    ]), 'missing real packaged guest assertions'
    assert text.count(f'web fetch transport: {EXPECTED}/{EXPECTED} passed; real sockets/TLS; policy dependency adapters; 100 close cycles') == 1
    assert len(re.findall(r'^WEB_FETCH_ARM_GUEST_COMPLETED=1$', text, re.M)) == 1, 'missing unique normal-completion receipt'
    assert not re.search(r'AssertionError|SyntaxError|uncaughtException|^FAIL ', text, re.M), 'guest contains failed assertion'
    return passed


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = json.loads(args.result.read_text(encoding='utf-8'))
    passed = check(result, args.output.read_text(encoding='utf-8'))
    print(f'WEB_FETCH_GUEST_VERIFIED={len(passed)} wait=0 normal_before_90s=true pipe_eof=true reader=false residual=false')
