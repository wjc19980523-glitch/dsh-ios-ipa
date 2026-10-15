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
# Keep evidence outside the disposable fixture, including on a nonzero exit.
mkdir -p "$ROOT/cilogs-verify"
DIAGNOSTICS="$(mktemp -d "$ROOT/cilogs-verify/job-tracking.XXXXXX")"
export DSH_JOB_TRACE_FILE="$DIAGNOSTICS/phases.jsonl"
: > "$DSH_JOB_TRACE_FILE"
# The existing supervisor owns this one process group and its actual wait status.
# 75-second sampling is independent of the 90-second deadline. Neither timeout
# nor an early printed pass sentinel can make this suite successful.
set +e
python3 "$HERE/guest-runner.py" run --host-only --phase job-tracking \
  --result "$DIAGNOSTICS/result.json" --events "$DSH_JOB_TRACE_FILE" \
  --timeout 90 --sample-after 75 -- bash -c '
    set -euo pipefail
    phase() {
      printf "{\"schema\":1,\"phase\":\"job-tracking\",\"fileTag\":\"shell\",\"event\":\"%s\",\"pid\":%d}\n" "$1" "$$" >> "$DSH_JOB_TRACE_FILE"
    }
    # Uses the already-present image; no npm install or network download.
    phase prepare:start
    python3 "$1/job-tracking-prepare.py" --fixtures "$2"
    phase prepare:done
    export DSH_JOB_FIXTURES="$2"
    phase syntax:start
    node --check "$2/bridge-patched.mjs"
    phase syntax:done
    phase suite:start
    node --import "$1/job-tracking-trace.mjs" --test --test-reporter=tap \
      "$1/job-ledger-test.mjs" "$1/job-tracking-runtime-test.mjs" "$1/development-tools-test.mjs"
    phase suite:done
  ' bash "$HERE" "$WORK" 2>&1 | tee "$DIAGNOSTICS/suite.log"
PIPELINE_STATUS=("${PIPESTATUS[@]}")
set -e
# A simultaneous tee failure must not hide the supervised command's exit code.
if [ "${PIPELINE_STATUS[0]}" -ne 0 ]; then exit "${PIPELINE_STATUS[0]}"; fi
if [ "${PIPELINE_STATUS[1]}" -ne 0 ]; then exit "${PIPELINE_STATUS[1]}"; fi
python3 "$HERE/check-job-tracking-result.py" --expected 60 \
  --result "$DIAGNOSTICS/result.json" --log "$DIAGNOSTICS/suite.log"
