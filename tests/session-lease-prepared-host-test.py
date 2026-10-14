#!/usr/bin/env python3
"""Run real host-file proof cases and require the removed-hash negative control."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', default='node')
    options = parser.parse_args()
    for negative in (False, True):
        command = [options.node, str(ROOT / 'tests/session-lease-prepared-test.mjs')]
        if negative:
            command.append('--negative-control=no-hash')
        result = subprocess.run(command, cwd=ROOT, capture_output=True, encoding='utf-8', errors='replace', timeout=60)
        if not negative:
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            if result.returncode != 0 or 'SESSION_PREPARED_HOST_TESTS 32/32; native_flock_executed=false' not in result.stdout:
                return 1
        elif (result.returncode != 1 or 'Missing expected rejection' not in result.stderr
              or 'SESSION_PREPARED_HOST_TESTS' in result.stdout):
            print('removed-hash negative control was not rejected by its intended assertion', file=sys.stderr)
            return 1
        else:
            print('PASS removed-hash negative control rejected; real_exit=1; assertion=Missing expected rejection')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
