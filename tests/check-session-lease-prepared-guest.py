#!/usr/bin/env python3
"""Verify each independently supervised 90-second prepared-checkpoint guest case."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('session_lease_receipt', HERE / 'check-session-lease-guest.py')
STRICT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STRICT)
COUNTS = {'safety': 11, 'large': 1}


def verify(result, text, mode, encoding):
    if mode not in COUNTS or encoding not in ('none', 'zstd') or not isinstance(text, str):
        return False
    if not STRICT.execution_ok(result, f'session-prepared-{mode}-{encoding}'):
        return False
    expected = COUNTS[mode]
    receipt = f'SESSION_PREPARED_GUEST_TESTS {expected}/{expected}; native_flock_executed=true; mode={mode}; encoding={encoding}'
    lines = text.splitlines()
    passes = [line for line in lines if re.match(r'^\s*PASS\b', line)]
    names = [line[5:] for line in passes]
    if (len(names) != expected or len(set(names)) != expected or not all(names)
            or any(line != 'PASS ' + name for line, name in zip(passes, names))
            or [line for line in lines if 'SESSION_PREPARED_GUEST_TESTS' in line] != [receipt]
            or any(lines.index('PASS ' + name) > lines.index(receipt) for name in names)
            or re.search(r'AssertionError|uncaughtException|unhandledRejection|^\s*FAIL\b|^\s*(?:[A-Za-z][A-Za-z0-9_.]*Error|Error)(?:\s*\[[^\]\n]+\])?:', text, re.M)):
        return False
    if mode == 'large':
        timing = [line.removeprefix('SESSION_PREPARED_TIMING ') for line in lines if line.startswith('SESSION_PREPARED_TIMING ')]
        if len(timing) != 1:
            return False
        try:
            value = json.loads(timing[0])
            integers = lambda xs: all(type(x) is int and x >= 0 for x in xs)
            return (value['encoding'] == encoding and len(value['physical_log_bytes']) == 4
                    and integers(value['physical_log_bytes']) and min(value['physical_log_bytes']) > 0
                    and value['semantic_title_bytes'] == 11141120
                    and value['full']['background_full_decode_count'] == 4
                    and value['clean']['background_full_decode_count'] == 0
                    and value['clean']['prepared_verified_count'] == 4
                    and value['dirty']['background_full_decode_count'] == 1
                    and value['dirty']['prepared_verified_count'] == 3
                    and integers(x for key in ('full', 'clean', 'dirty') for x in value[key].values())
                    and value['clean']['raw_verified_bytes'] == sum(value['physical_log_bytes']))
        except (KeyError, TypeError, ValueError):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=tuple(COUNTS), required=True)
    parser.add_argument('--encoding', choices=('none', 'zstd'), required=True)
    options = parser.parse_args()
    try:
        result = json.loads(options.result.read_text(encoding='utf-8'))
        text = options.output.read_text(encoding='utf-8')
    except (OSError, ValueError, UnicodeError) as error:
        print('prepared guest evidence unavailable: ' + type(error).__name__, file=sys.stderr)
        return 2
    if not verify(result, text, options.mode, options.encoding):
        print('prepared guest assertions or real execution evidence incomplete', file=sys.stderr)
        return 1
    print(f'SESSION_PREPARED_ASSERTIONS_VERIFIED={COUNTS[options.mode]}; mode={options.mode}; encoding={options.encoding}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
