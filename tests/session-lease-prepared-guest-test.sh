#!/usr/bin/env bash
# Separate from the unchanged 18-test/100-cycle command. Each case keeps 90s.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ISH_SRC="${ISH_SRC:-$ROOT/ish-arm64}"
ISH_BUILD="${ISH_BUILD:-$ISH_SRC/build-arm64-release}"
TARBALL="${1:-$ROOT/build/root.tar.gz}"
GUEST_TIMEOUT=90
GUEST_SEQUENCE=0
GUEST_FAILURES=0
GUEST_STATUS=0
mkdir -p "$ROOT/build"
WORK="${WORK:-$(mktemp -d "$ROOT/build/session-lease-prepared.XXXXXX")}"
[ -f "$TARBALL" ] && [ -x "$ISH_BUILD/ish" ] && [ -x "$ISH_BUILD/tools/fakefsify" ] || {
  echo 'missing rootfs archive or built guest tools' >&2; exit 2;
}
[ ! -e "$WORK/fakefs" ] || { echo 'private clone already exists' >&2; exit 2; }
export DSH_TEST_EVENT_LOG="$WORK/service-events.jsonl"
export DSH_TEST_PHASE_FILE="$WORK/current-phase"
: > "$DSH_TEST_EVENT_LOG"
. "$HERE/guest-helper.sh"
"$ISH_BUILD/tools/fakefsify" "$TARBALL" "$WORK/fakefs"
INSTALL_COMMAND="$(python3 "$HERE/session-lease-prepare.py" --output "$WORK/prepared-installer.mjs" --include-prepared-test)"
install_status=0
guest "$INSTALL_COMMAND" session-prepared-install "$WORK/prepared-installer.mjs" > "$WORK/prepared-install.log" 2>&1 || install_status=$?
cat "$WORK/prepared-install.log"
[ "$install_status" = 0 ] || exit "$install_status"
grep -qx 'SESSION_LEASE_PATCH_INSTALLED' "$WORK/prepared-install.log" || exit 1
for mode in safety large; do
  for encoding in none zstd; do
    status=0
    guest "unset DSH_SESSION_LIFECYCLE DSH_HOST_BRIDGE_URL DSH_HOST_BRIDGE_TOKEN; node --expose-internals --expose-gc /tmp/dsh-session-prepared-test.mjs $mode $encoding" "session-prepared-$mode-$encoding" > "$WORK/prepared-$mode-$encoding.log" 2>&1 || status=$?
    cat "$WORK/prepared-$mode-$encoding.log"
    [ "$status" = 0 ] || exit "$status"
    python3 "$HERE/check-session-lease-prepared-guest.py" --result "$GUEST_RESULT" --output "$WORK/prepared-$mode-$encoding.log" --mode "$mode" --encoding "$encoding"
  done
done
[ "$GUEST_FAILURES" = 0 ]
echo 'SESSION_PREPARED_GUEST_RUNNER_COMPLETED=4'
