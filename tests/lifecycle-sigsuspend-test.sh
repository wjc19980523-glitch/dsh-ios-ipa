#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain enabled (Linux runs leak detection)'
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-sigsuspend.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/production-sigsuspend.h" "$WORK/test"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
# Compile these production functions verbatim, avoiding unrelated ARM64 signal
# frame assembly. Real task/sighand structures and production wait_for remain.
python3 - "$ROOT/ish-arm64/kernel/signal.c" "$WORK/production-sigsuspend.h" <<'PY'
import re, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
out = []
for name in ['sigset_size_valid', 'user_get_sigset', 'sigmask_set',
             'sigmask_set_temp_unlocked', 'sys_rt_sigsuspend']:
    match = re.search(r'(?m)^(?:static )?[^;{}\n]*\b' + name + r'\([^;{}]*\)\s*\{', source)
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
build_and_run() {
  "${CC:-cc}" -std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 -Wall -Wextra -Werror \
    -Wno-unused-parameter -pthread "$@" -I"$ROOT/ish-arm64" -I"$WORK" \
    "$ROOT/tests/lifecycle-sigsuspend-test.c" "$ROOT/ish-arm64/util/sync.c" \
    "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test"
}
build_and_run
if "${CC:-cc}" -fsanitize=address,undefined -x c - -o "$WORK/test" <<< 'int main(void) { return 0; }'; then
  build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
else
  echo 'note sigsuspend: compiler does not support ASan/UBSan; ordinary production wait regression passed'
fi
RUNNER_COMPLETED=1
