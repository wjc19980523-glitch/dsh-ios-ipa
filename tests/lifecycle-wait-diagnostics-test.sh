#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-wait-diagnostics.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/test"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
fi
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
build_and_run() {
  "${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$@" -I"$ROOT/ish-arm64" \
    "$ROOT/tests/lifecycle-wait-diagnostics-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test"
}
build_and_run
build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
RUNNER_COMPLETED=1
