#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-task-context.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/production-task-loop.h" "$WORK/production-legacy-task-loop.h" "$WORK/production-interrupt-admission.h" "$WORK/test" "$WORK/legacy-test"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
# Compile the actual CPU loop and pthread cleanup verbatim. Only the emulator
# quantum and syscall body are controlled; admission is the production prefix
# of handle_interrupt, including its cleanup-attribute identity restoration.
python3 - "$ROOT/ish-arm64" "$WORK" <<'PY'
import re, sys
from pathlib import Path
root, work = map(Path, sys.argv[1:])
def function(source, name):
    match = re.search(r'(?m)^(?:static )?[^;{}\n]*\b' + name + r'\([^;{}]*\)\s*\{', source)
    if not match: raise SystemExit(f'Production function not found: {name}')
    depth = 1
    for token in re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', source[match.end():]):
        if token.group() == '{': depth += 1
        elif token.group() == '}': depth -= 1
        if depth == 0: return source[match.start():match.end() + token.end()]
    raise SystemExit(f'Unbalanced production function: {name}')
task = (root / 'kernel/task.c').read_text()
production = '\n\n'.join(function(task, name) for name in ['task_run_tlb_cleanup', 'task_run_current'])
(work / 'production-task-loop.h').write_text(production)
# A negative control removes only the outer-loop binding. It must reproduce
# the real failure even though the same production syscall prefix grants entry.
pattern = r'        struct dsh_lifecycle_guest_context iteration_guest_context = \{self->pid, self->tgid\};\s*struct dsh_lifecycle_guest_context previous_guest_context\s*__attribute__\(\(cleanup\(dsh_lifecycle_restore_guest_context\)\)\) =\s*dsh_lifecycle_exchange_guest_context\(iteration_guest_context\);'
legacy, count = re.subn(pattern, '', production)
if count != 1: raise SystemExit('Outer task context negative control must remove exactly one binding')
(work / 'production-legacy-task-loop.h').write_text(legacy)
calls = (root / 'kernel/calls.c').read_text()
entry = function(calls, 'handle_interrupt')
body = entry[entry.index('{') + 1:entry.index('    if (interrupt == INT_SYSCALL) {')]
(work / 'production-interrupt-admission.h').write_text(
    function(calls, 'lifecycle_pure_wait') + '\n\nvoid handle_interrupt(int interrupt) {\n' + body + '\n    controlled_syscall_body();\n}\n')
PY
build_and_run() {
  local flags=("$@")
  local common=(-std=gnu11 -D_GNU_SOURCE=1 -DGUEST_ARM64=1 -Wall -Wextra -Werror
    -Wno-unused-parameter -pthread -I "$ROOT/ish-arm64" -I "$WORK")
  if [ "$(uname -s)" = Darwin ]; then common+=(-fblocks); fi
  "${CC:-cc}" "${common[@]}" ${flags[@]+"${flags[@]}"} "$ROOT/tests/task-lifecycle-context-test.c" \
    "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test"
  "${CC:-cc}" "${common[@]}" ${flags[@]+"${flags[@]}"} -DLEGACY_LOOP_NEGATIVE_CONTROL=1 \
    "$ROOT/tests/task-lifecycle-context-test.c" "$ROOT/ish-arm64/fs/dsh-lifecycle.c" -o "$WORK/legacy-test"
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/legacy-test"
}
if [ "$(uname -s)" = Darwin ]; then
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan remain mandatory'
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
fi
build_and_run
build_and_run -fsanitize=address,undefined -fno-omit-frame-pointer
RUNNER_COMPLETED=1
