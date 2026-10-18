#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-asbestos-links.XXXXXX")"
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; rm -f "$WORK/test" "$WORK/legacy-test" "$WORK/legacy-asbestos.c" "$WORK/legacy.log"; rmdir "$WORK"; exit "$cleanup_rc"' EXIT
if [[ "$(uname -s)" == Darwin ]]; then
  GC_FLAGS=(-Wl,-dead_strip)
  PLATFORM_FLAGS=(-fblocks)
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
else
  GC_FLAGS=(-Wl,--gc-sections)
  PLATFORM_FLAGS=()
fi
EXTRA_FLAGS=()
if [[ -n "${CFLAGS:-}" ]]; then read -r -a EXTRA_FLAGS <<< "$CFLAGS"; fi
build() {
  local output="$1"; shift
  "${CC:-cc}" -std=gnu11 -D_GNU_SOURCE -DGUEST_ARM64=1 -O1 -g \
    -ffunction-sections -fdata-sections -pthread -I"$ROOT/ish-arm64" \
    ${PLATFORM_FLAGS[@]+"${PLATFORM_FLAGS[@]}"} \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$@" \
    "$ROOT/tests/asbestos-block-links-test.c" "${GC_FLAGS[@]}" -o "$output"
}
build "$WORK/test"
"$WORK/test"
build "$WORK/test" -fsanitize=address,undefined -fno-omit-frame-pointer
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1}" UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" "$WORK/test"

# Negative control changes only the matching predicate in a temporary copy of
# the production helper. The legacy low-32-bit comparison must deterministically
# fail the collision assertion before corrupted lists can be traversed.
python3 - "$ROOT/ish-arm64/asbestos/asbestos.c" "$WORK/legacy-asbestos.c" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'static\s+(?:inline\s+)?bool\s+fiber_block_link_if_matching\s*\(', source)
if not match:
    raise SystemExit('missing production block-link helper')
start = source.index('{', match.start())
depth = 1
end = start + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
body = source[start:end]
predicate = 'if (!(destination & guest_tag) || (addr_t)(destination & ~guest_tag) != target->addr)'
if body.count(predicate) != 1:
    raise SystemExit('production block-link predicate changed; review negative control')
legacy = body.replace(predicate, '(void)guest_tag;\n    if ((destination & 0xffffffffUL) != target->addr)')
pathlib.Path(sys.argv[2]).write_text(source[:start] + legacy + source[end:])
PY
legacy_control() {
  build "$WORK/legacy-test" "-DDSH_ASBESTOS_SOURCE_FILE=\"$WORK/legacy-asbestos.c\"" "$@"
  # The expected failure exits before traversing the corrupted graph, so only
  # this negative control intentionally leaves fixture allocations for exit.
  if ASAN_OPTIONS="${ASAN_OPTIONS:+${ASAN_OPTIONS}:}detect_leaks=0" \
      UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
      "$WORK/legacy-test" --collision-only >"$WORK/legacy.log" 2>&1; then
    cat "$WORK/legacy.log"
    echo 'FAIL legacy block-link predicate unexpectedly passed' >&2
    exit 1
  fi
  grep -q 'FAIL already-patched slot must not relink' "$WORK/legacy.log"
  echo 'ASBESTOS_BLOCK_LINK_LEGACY_NEGATIVE_CONTROL rejected'
}
legacy_control
legacy_control -fsanitize=address,undefined -fno-omit-frame-pointer
RUNNER_COMPLETED=1
