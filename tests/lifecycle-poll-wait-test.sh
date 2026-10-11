#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain enabled (Linux runs leak detection)'
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-lifecycle-poll.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/core.o" "$WORK/poll.o" "$WORK/poll-test"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
if [ "$(uname -s)" = Darwin ]; then DEAD_STRIP=-Wl,-dead_strip; else DEAD_STRIP=-Wl,--gc-sections; fi
build_and_run() {
  local flags=("$@")
  local common=(-std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 -Wall -Wextra -Werror
    -Wno-unused-parameter -ffunction-sections -fdata-sections -pthread -I "$ROOT/ish-arm64")
  "${CC:-cc}" "${common[@]}" ${flags[@]+"${flags[@]}"} -Dclock_gettime=lifecycle_test_clock_gettime \
    -c "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/core.o"
  "${CC:-cc}" "${common[@]}" ${flags[@]+"${flags[@]}"} -Dclock_gettime=lifecycle_test_clock_gettime \
    -c "$ROOT/ish-arm64/fs/poll.c" -o "$WORK/poll.o"
  "${CC:-cc}" "${common[@]}" ${flags[@]+"${flags[@]}"} "$ROOT/tests/lifecycle-poll-wait-test.c" \
    "$WORK/core.o" "$WORK/poll.o" "$DEAD_STRIP" -o "$WORK/poll-test"
  for scenario in group-exit stale recent-resume quiescing idle; do
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
      "$WORK/poll-test" "$scenario"
  done
}
build_and_run
if "${CC:-cc}" -fsanitize=address,undefined -x c - -o "$WORK/poll-test" <<< 'int main(void) { return 0; }'; then
  # Match meson.build: list sentinels form synthetic container pointers whose
  # alignment is not that of struct task. Keep all other UB checks enabled.
  build_and_run -fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer
else
  echo 'note poll-wait: compiler does not support ASan/UBSan; ordinary native-poll regression passed'
fi
RUNNER_COMPLETED=1
