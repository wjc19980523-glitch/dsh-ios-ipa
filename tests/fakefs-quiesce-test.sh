#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain enabled (Linux runs leak detection)'
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-fakefs-quiesce.XXXXXX")"
cleanup() {
  for scenario in before during precommit cancel; do
    rm -f "$WORK/$scenario/meta.db" "$WORK/$scenario/meta.db-wal" "$WORK/$scenario/meta.db-shm" \
      "$WORK/$scenario/primary" "$WORK/$scenario/late" "$WORK/$scenario/sentinel"
    rm -f "$WORK/$scenario/config.yml" "$WORK/$scenario/api-key.fixture" \
      "$WORK/$scenario/session.fixture" "$WORK/$scenario/workspace.fixture"
    rmdir "$WORK/$scenario" 2>/dev/null || true
  done
  rm -f "$WORK/test"
  rmdir "$WORK"
}
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; cleanup; exit "$cleanup_rc"' EXIT
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
LINK_FLAGS=(-Wl,--gc-sections)
if [[ "$(uname -s)" == Darwin ]]; then LINK_FLAGS=(-Wl,-dead_strip); EXTRA_FLAGS+=(-fblocks); fi
build_and_run() {
  "${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread -ffunction-sections -fdata-sections \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$@" -I"$ROOT/ish-arm64" \
    "$ROOT/tests/fakefs-quiesce-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/fs/fake-db.c" "$ROOT/ish-arm64/fs/fake-migrate.c" \
    "$ROOT/ish-arm64/fs/fake-rebuild.c" "${LINK_FLAGS[@]}" -lsqlite3 -o "$WORK/test"
  for scenario in before during precommit cancel; do
    mkdir -p "$WORK/$scenario"
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
      "$WORK/test" "$scenario" "$WORK/$scenario/meta.db" "$WORK/$scenario"
    rm -f "$WORK/$scenario/meta.db" "$WORK/$scenario/meta.db-wal" "$WORK/$scenario/meta.db-shm" \
      "$WORK/$scenario/primary" "$WORK/$scenario/late" "$WORK/$scenario/sentinel"
    rm -f "$WORK/$scenario/config.yml" "$WORK/$scenario/api-key.fixture" \
      "$WORK/$scenario/session.fixture" "$WORK/$scenario/workspace.fixture"
  done
}
build_and_run
if "${CC:-cc}" -fsanitize=address,undefined -x c - -o "$WORK/test" <<< 'int main(void) { return 0; }'; then
  build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
else
  echo 'note fakefs-quiesce: compiler does not support ASan/UBSan; real SQLite regression passed'
fi
RUNNER_COMPLETED=1
