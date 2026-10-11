#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-tty-read.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/production-tty-read.h" "$WORK/production-tty-winsize.h" "$WORK/production-terminal-resize.h" "$WORK/test" "$WORK/winsize-test"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
# Execute production functions verbatim using real task/TTY/fd structures and
# wait_for. Avoid linking unrelated emulator assembly and device drivers.
python3 - "$ROOT/ish-arm64" "$WORK/production-tty-read.h" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
out = re.findall(r'(?m)^#define (?:F_\w+|FD_ALLOWED_FLAGS)\b[^\n]*', (root / 'fs/fd.c').read_text())
sources = {
    'fs/fd.c': ['fd_create', 'fd_retain', 'fd_close', 'fdtable_resize', 'fdtable_expand',
                'fdtable_get', 'f_get', 'f_get_retained', 'f_install_start', 'fdtable_close',
                'f_close', 'f_install', 'sys_dup', 'sys_dup3', 'fd_getflags', 'fd_setflags', 'f_dupfd', 'sys_fcntl'],
    'fs/tty.c': ['tty_read_into_buf', 'tty_canon_size', 'pty_is_half_closed_master',
                 'tty_is_current', 'tty_signal_if_background', 'tty_read'],
    'kernel/fs.c': ['sys_read_buf', 'sys_read', 'read_iovec', 'iovec_size', 'sys_readv', 'sys_preadv2'],
    'kernel/calls.c': ['fast_read'],
}
for path, names in sources.items():
    source = (root / path).read_text()
    for name in names:
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
    "$ROOT/tests/lifecycle-tty-read-test.c" "$ROOT/ish-arm64/util/sync.c" \
    "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test"
}
build_and_run
if "${CC:-cc}" -fsanitize=address,undefined -x c - -o "$WORK/test" <<< 'int main(void) { return 0; }'; then
  build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
else
  echo 'note tty-read: compiler lacks ASan/UBSan; ordinary production tests passed'
fi
# Keep the existing six groups above; exercise the real resize/read lock order
# independently, including the native Terminal.m call body and master/slave ioctl.
python3 - "$ROOT/ish-arm64" "$WORK" <<'PY'
import re, sys
from pathlib import Path
root, work = Path(sys.argv[1]), Path(sys.argv[2])
out = []
for path, names in {
    'fs/tty.c': ['tty_read_into_buf', 'tty_canon_size', 'pty_is_half_closed_master',
                 'tty_is_current', 'tty_signal_if_background', 'tty_read',
                 'tty_update_winsize_locked', 'tty_mode_ioctl', 'tty_ioctl', 'tty_set_winsize'],
    'kernel/signal.c': ['send_group_signal'],
}.items():
    source = (root / path).read_text()
    for name in names:
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
(work / 'production-tty-winsize.h').write_text('\n\n'.join(out))
terminal = (root / 'app/Terminal.m').read_text()
start = terminal.index('- (void)syncWindowSize')
start = terminal.index('#if !ISH_LINUX', start) + len('#if !ISH_LINUX')
end = terminal.index('#else', start)
(work / 'production-terminal-resize.h').write_text(terminal[start:end])
PY
build_and_run_winsize() {
  "${CC:-cc}" -std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 -Wall -Wextra -Werror \
    -Wno-unused-parameter -pthread "$@" -I"$ROOT/ish-arm64" -I"$WORK" \
    "$ROOT/tests/tty-winsize-lock-test.c" "$ROOT/ish-arm64/util/sync.c" -o "$WORK/winsize-test"
  for scenario in host slave master state; do
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/winsize-test" "$scenario"
  done
}
build_and_run_winsize
if "${CC:-cc}" -fsanitize=address,undefined -x c - -o "$WORK/winsize-test" <<< 'int main(void) { return 0; }'; then
  build_and_run_winsize -fsanitize=address,undefined -fno-omit-frame-pointer
else
  echo 'note tty-winsize: compiler lacks ASan/UBSan; ordinary production tests passed'
fi
RUNNER_COMPLETED=1
