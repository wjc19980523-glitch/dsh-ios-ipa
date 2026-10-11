#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-legacy-fakefs.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -rf "$WORK"; exit "$cleanup_rc"' EXIT
# UML kernel headers are unavailable on the host runner. Compile the actual
# production transaction wrappers with small VFS shims, not a copied model.
python3 - "$ROOT/ish-arm64/linux/fakefs.c" "$WORK/legacy-wrappers.h" <<'PY'
import re, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
names = ['fakefs_db_error', 'fakefs_rollback_error', 'fakefs_finish_read',
         'dentry_name', 'open_fd_for_dentry', 'fakefs_make_node', 'fakefs_create',
         'fakefs_rename', 'fakefs_link', 'unlink_common', 'fakefs_unlink',
         'fakefs_rmdir', 'fakefs_symlink', 'fakefs_mkdir', 'fakefs_mknod',
         'fakefs_iterate']
out = []
for name in names:
    match = re.search(r'(?m)^static [^;{}]*\b' + name + r'\([^;{}]*\)\s*\{', source)
    if not match:
        raise SystemExit(f'Production function not found: {name}')
    start, depth = match.start(), 1
    # Skip comment/string contents when matching function braces.
    tokens = re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', source[match.end():])
    for token in tokens:
        if token.group() == '{': depth += 1
        elif token.group() == '}': depth -= 1
        if depth == 0:
            out.append(source[start:match.end() + token.end()])
            break
    else:
        raise SystemExit(f'Unbalanced production function: {name}')
Path(sys.argv[2]).write_text('\n\n'.join(out))
PY
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
LINK_FLAGS=(-Wl,--gc-sections)
if [[ "$(uname -s)" == Darwin ]]; then LINK_FLAGS=(-Wl,-dead_strip); EXTRA_FLAGS+=(-fblocks); fi
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -pthread \
    -DDSH_DB_TRANSACTION_TIMEOUT_MS=40 -ffunction-sections -fdata-sections \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -I"$ROOT/ish-arm64" -I"$WORK" \
    "$ROOT/tests/legacy-fakefs-wrapper-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" \
    "$ROOT/ish-arm64/fs/fake-db.c" "$ROOT/ish-arm64/fs/fake-migrate.c" \
    "$ROOT/ish-arm64/fs/fake-rebuild.c" "${LINK_FLAGS[@]}" -lsqlite3 -o "$WORK/test"
"$WORK/test" "$WORK/meta.db" "$WORK"
RUNNER_COMPLETED=1
