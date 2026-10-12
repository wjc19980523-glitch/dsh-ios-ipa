#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-session-drain.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/test" "$WORK/test-asan" "$WORK/flock-fixture"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
"${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
  -I "$ROOT/ish-arm64" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
  "$ROOT/tests/session-drain-admission-test.c" -o "$WORK/test"
"$WORK/test" "$WORK/flock-fixture"
"${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I "$ROOT/ish-arm64" \
  "$ROOT/ish-arm64/fs/dsh-lifecycle.c" "$ROOT/tests/session-drain-admission-test.c" \
  -o "$WORK/test-asan"
if [ "$(uname -s)" = Darwin ]; then
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain mandatory'
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
else
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}"
fi
UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test-asan" "$WORK/flock-fixture"
RUNNER_COMPLETED=1
