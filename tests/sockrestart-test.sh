#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
  echo 'note sanitizer: Apple runtime lacks LeakSanitizer; ASan/UBSan and explicit fd/allocation/retain balances remain enabled'
fi
test_directory=$(cd "$(dirname "$0")" && pwd)
repository="${DSH_SOCKRESTART_REPO:-$(cd "$test_directory/.." && pwd)}"
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/dsh-sockrestart-test.XXXXXX")
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -rf "$build_directory"; exit "$cleanup_rc"' EXIT
mkdir -p "$build_directory/stubs/fs" "$build_directory/stubs/kernel"
# Only kernel types are supplied by the test. The actual sockrestart source,
# socket API, list implementation and all recovery branches are compiled.
for header in fs/fd.h fs/sock.h kernel/task.h; do
  printf '// Kernel types are declared by sockrestart-test.c\n' > "$build_directory/stubs/$header"
done
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
  -I "$build_directory/stubs" -I "$repository/ish-arm64" \
  "-DSOCKRESTART_SOURCE=\"$repository/ish-arm64/fs/sockrestart.c\"" \
  "$test_directory/sockrestart-test.c" -o "$build_directory/sockrestart-test"
"$build_directory/sockrestart-test"
if "${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$build_directory/stubs" -I "$repository/ish-arm64" \
  "-DSOCKRESTART_SOURCE=\"$repository/ish-arm64/fs/sockrestart.c\"" \
  "$test_directory/sockrestart-test.c" -o "$build_directory/sockrestart-test-asan"; then
  ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" \
    UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$build_directory/sockrestart-test-asan"
else
  echo 'note sockrestart: compiler does not support ASan/UBSan; ordinary syscall regression passed'
fi
RUNNER_COMPLETED=1
