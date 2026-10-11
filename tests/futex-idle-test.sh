#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-futex-idle.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/test"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain enabled (Linux runs leak detection)'
  LINK_GC=(-Wl,-dead_strip)
else
  LINK_GC=(-Wl,--gc-sections)
fi
build_and_run() {
  "${CC:-cc}" -std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 -Wall -Wextra -Werror \
    -Wno-unused-parameter -ffunction-sections -fdata-sections -pthread "$@" \
    -I"$ROOT/ish-arm64" "$ROOT/tests/futex-idle-test.c" \
    "$ROOT/ish-arm64/util/sync.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "${LINK_GC[@]}" -o "$WORK/test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test"
}
build_and_run
if "${CC:-cc}" -fsanitize=address,undefined -x c - -o "$WORK/test" <<< 'int main(void) { return 0; }'; then
  build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
else
  echo 'note futex idle: compiler lacks ASan/UBSan; ordinary production tests passed'
fi
RUNNER_COMPLETED=1
