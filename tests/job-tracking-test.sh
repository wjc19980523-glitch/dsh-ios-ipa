#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-job-tracking.XXXXXX")"
case "$WORK" in /*/dsh-job-tracking.??????) ;; *) echo 'unsafe fixture path' >&2; exit 1 ;; esac
cleanup() {
  status=$?
  trap - EXIT
  if ! rm -rf -- "$WORK"; then
    echo 'test fixture cleanup failed' >&2
    if [ "$status" -eq 0 ]; then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT
# Uses the already-present image, not npm install or any network download.
python3 "$HERE/job-tracking-prepare.py" --fixtures "$WORK"
export DSH_JOB_FIXTURES="$WORK"
node --check "$WORK/bridge-patched.mjs"
node --test "$HERE/job-ledger-test.mjs" "$HERE/job-tracking-runtime-test.mjs" "$HERE/development-tools-test.mjs"
