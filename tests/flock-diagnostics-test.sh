#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-flock-diagnostics.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/test" "$WORK/production-flock.h" "$WORK/session.lock"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
if [[ "$(uname -s)" == Darwin ]]; then
  EXTRA_FLAGS+=(-fblocks)
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; Linux runs leak detection'
fi
# Compile the actual production functions, not copies maintained in a test.
# Only the fd lookup and failure-injected host calls below are test shims.
python3 - "$ROOT" "$WORK/production-flock.h" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
out = []
for relative, names in [('ish-arm64/fs/real.c', ['getpath', 'realfs_flock_identity', 'realfs_flock', 'realfs_close']),
                        ('ish-arm64/kernel/fs.c', ['sys_flock'])]:
    source = (root / relative).read_text()
    for name in names:
        match = re.search(r'(?m)^[\w *]+\b' + name + r'\([^;{}]*\)\s*\{', source)
        if not match: raise SystemExit(f'Production function not found: {name}')
        depth = 1
        for token in re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', source[match.end():]):
            if token.group() == '{': depth += 1
            elif token.group() == '}': depth -= 1
            if depth == 0:
                body = source[match.start():match.end() + token.end()]
                if name == 'getpath':
                    body = body.replace('getpath(', 'production_getpath(', 1)
                    body += '\nstatic int getpath(int fd, char *buf) { if (fail_path) { errno = EACCES; return -1; } return production_getpath(fd, buf); }'
                out.append(body)
                break
        else: raise SystemExit(f'Unbalanced production function: {name}')
Path(sys.argv[2]).write_text('\n\n'.join(out))
PY
build_and_run() {
  "${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$@" -I"$ROOT/ish-arm64" -I"$WORK" \
    "$ROOT/tests/flock-diagnostics-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
    "$WORK/test" "$WORK/session.lock"
}
build_and_run
build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
RUNNER_COMPLETED=1
