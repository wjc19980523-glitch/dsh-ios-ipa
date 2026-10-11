#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain enabled (Linux runs leak detection)'
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-lifecycle-admission.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/admission-test" "$WORK/admission-test-asan" "$WORK/poll-cleanup-test" "$WORK/poll-cleanup-test-asan" "$WORK/flock-fixture"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
"${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
  -I "$ROOT/ish-arm64" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
  "$ROOT/tests/lifecycle-admission-test.c" -o "$WORK/admission-test"
"$WORK/admission-test" "$WORK/flock-fixture"
if [ "$(uname -s)" = Darwin ]; then
  DEAD_STRIP=-Wl,-dead_strip
else
  DEAD_STRIP=-Wl,--gc-sections
fi
"${CC:-cc}" -std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 \
  -Wall -Wextra -Werror -Wno-unused-parameter -ffunction-sections -fdata-sections \
  -pthread -I "$ROOT/ish-arm64" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
  "$ROOT/ish-arm64/kernel/poll.c" "$ROOT/tests/lifecycle-poll-cleanup-test.c" \
  "$DEAD_STRIP" -o "$WORK/poll-cleanup-test"
"$WORK/poll-cleanup-test" "$WORK/flock-fixture"
if "${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I "$ROOT/ish-arm64" \
  "$ROOT/ish-arm64/fs/dsh-lifecycle.c" "$ROOT/tests/lifecycle-admission-test.c" \
  -o "$WORK/admission-test-asan"; then
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
    "$WORK/admission-test-asan" "$WORK/flock-fixture"
  "${CC:-cc}" -std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 \
    -Wall -Wextra -Werror -Wno-unused-parameter -ffunction-sections -fdata-sections \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -pthread -I "$ROOT/ish-arm64" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/kernel/poll.c" "$ROOT/tests/lifecycle-poll-cleanup-test.c" \
    "$DEAD_STRIP" -o "$WORK/poll-cleanup-test-asan"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
    "$WORK/poll-cleanup-test-asan" "$WORK/flock-fixture"
else
  echo 'note admission: compiler does not support ASan/UBSan; ordinary pthread regression passed'
fi
bash "$ROOT/tests/lifecycle-poll-wait-test.sh"
RUNNER_COMPLETED=1
