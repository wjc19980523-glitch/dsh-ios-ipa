#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-lifecycle.XXXXXX")"
# Bash 3.2 can enter EXIT with status 0 after nounset. Require the real tests
# to reach the end as well as preserving nonzero compiler/test exit codes.
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/lifecycle-test" "$WORK/sqlite-lifecycle-test" "$WORK/fixture.db" "$WORK/fixture.db-wal" "$WORK/fixture.db-shm"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
"${CC:-cc}" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" \
    "$ROOT/ish-arm64/fs/dsh-lifecycle.c" "$ROOT/tests/lifecycle-test.c" \
    -o "$WORK/lifecycle-test"
"$WORK/lifecycle-test"
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" \
    "$ROOT/ish-arm64/fs/dsh-lifecycle.c" "$ROOT/ish-arm64/fs/fake-db.c" \
    "$ROOT/tests/sqlite-lifecycle-test.c" -lsqlite3 -o "$WORK/sqlite-lifecycle-test"
"$WORK/sqlite-lifecycle-test" "$WORK/fixture.db"
RUNNER_COMPLETED=1
