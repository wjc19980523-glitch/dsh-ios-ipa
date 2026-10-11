#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-db-failure.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/test" "$WORK/meta.db" "$WORK/meta.db-wal" "$WORK/meta.db-shm" "$WORK/existing" "$WORK/must-not-create" "$WORK/ioerr-target" "$WORK/mknod-success" "$WORK/mknod-close-failed" "$WORK/production-mknod.h" "$WORK/mount-target/marker" "$WORK/mount-test" "$WORK/init-test" "$WORK/migrate.db" "$WORK/migrate.db-wal" "$WORK/migrate.db-shm" "$WORK/fail.db" "$WORK/fail.db-wal" "$WORK/fail.db-shm" "$WORK/rebuild.db" "$WORK/rebuild.db-wal" "$WORK/rebuild.db-shm" "$WORK/one" "$WORK/two" "$WORK/umount-test" "$WORK/umount-preserved" "$WORK"/umount-*.db "$WORK"/umount-*.db-wal "$WORK"/umount-*.db-shm; rmdir "$WORK/mount-target" 2>/dev/null || true; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
LINK_FLAGS=(-Wl,--gc-sections)
if [[ "$(uname -s)" == Darwin ]]; then LINK_FLAGS=(-Wl,-dead_strip); EXTRA_FLAGS+=(-fblocks); fi
python3 - "$ROOT/ish-arm64/fs/real.c" "$WORK/production-mknod.h" <<'PY'
import re, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
out = []
for name in ['realfs_mknod_with_effect', 'realfs_mknod']:
    match = re.search(r'(?m)^int ' + name + r'\([^;{}]*\)\s*\{', source)
    if not match: raise SystemExit(f'Production function not found: {name}')
    depth = 1
    for token in re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', source[match.end():]):
        if token.group() == '{': depth += 1
        elif token.group() == '}': depth -= 1
        if depth == 0:
            out.append(source[match.start():match.end() + token.end()])
            break
    else: raise SystemExit(f'Unbalanced production function: {name}')
Path(sys.argv[2]).write_text('\n\n'.join(out))
PY
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
    -DDSH_DB_TRANSACTION_TIMEOUT_MS=80 -ffunction-sections -fdata-sections \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" -I"$WORK" \
    "$ROOT/tests/fakefs-db-failure-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/fs/fake-db.c" "$ROOT/ish-arm64/fs/fake-migrate.c" \
    "$ROOT/ish-arm64/fs/fake-rebuild.c" "${LINK_FLAGS[@]}" -lsqlite3 -o "$WORK/test"
"$WORK/test" "$WORK/meta.db" "$WORK"

"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
    -DDSH_DB_TRANSACTION_TIMEOUT_MS=80 ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" \
    "$ROOT/tests/fakefs-db-init-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/fs/fake-db.c" "$ROOT/ish-arm64/fs/fake-migrate.c" \
    "$ROOT/ish-arm64/fs/fake-rebuild.c" -lsqlite3 -o "$WORK/init-test"
"$WORK/init-test" "$WORK"

"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
    -ffunction-sections -fdata-sections ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" \
    "$ROOT/tests/fakefs-mount-recovery-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/fs/fake-db.c" "$ROOT/ish-arm64/fs/fake-migrate.c" \
    "$ROOT/ish-arm64/fs/fake-rebuild.c" "${LINK_FLAGS[@]}" -lsqlite3 -o "$WORK/mount-test"
"$WORK/mount-test"

"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
    -ffunction-sections -fdata-sections ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" \
    "$ROOT/tests/fakefs-umount-failure-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/fs/fake-db.c" "$ROOT/ish-arm64/fs/fake-migrate.c" \
    "$ROOT/ish-arm64/fs/fake-rebuild.c" "${LINK_FLAGS[@]}" -lsqlite3 -o "$WORK/umount-test"
for scenario in success busy closed-eintr closed-eio unclosed-eio ebadf; do
    "$WORK/umount-test" "$scenario" "$WORK/umount-$scenario.db" "$WORK"
done
RUNNER_COMPLETED=1
