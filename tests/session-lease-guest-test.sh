#!/usr/bin/env bash
# Execute the complete patched session backend and native flock in a private
# imported guest root. The shipped archive and the ordinary 62 cases stay intact.
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
WORK="${WORK:-$(mktemp -d "$ROOT/build/session-lease-guest.XXXXXX")}"
[ -f "$TARBALL" ] && [ -x "$ISH_BUILD/ish" ] && [ -x "$ISH_BUILD/tools/fakefsify" ] || {
  echo 'missing rootfs archive or built guest tools' >&2; exit 2;
}
[ ! -e "$WORK/fakefs" ] || { echo 'test clone already exists; refusing to replace it' >&2; exit 2; }
mkdir -p "$WORK"
export DSH_TEST_EVENT_LOG="$WORK/service-events.jsonl"
export DSH_TEST_PHASE_FILE="$WORK/current-phase"
: > "$DSH_TEST_EVENT_LOG"
. "$HERE/guest-helper.sh"
"$ISH_BUILD/tools/fakefsify" "$TARBALL" "$WORK/fakefs"
INSTALL_COMMAND="$(python3 "$HERE/session-lease-prepare.py" --output "$WORK/session-lease-installer.mjs" --include-guest-test)"
install_status=0
guest "$INSTALL_COMMAND" session-lease-install "$WORK/session-lease-installer.mjs" > "$WORK/session-install.log" 2>&1 || install_status=$?
cat "$WORK/session-install.log"
[ "$install_status" = 0 ] || exit "$install_status"
grep -qx 'SESSION_LEASE_PATCH_INSTALLED' "$WORK/session-install.log" || {
  echo 'guest patch installation did not complete' >&2; exit 1;
}
native_status=0
guest 'unset DSH_SESSION_LIFECYCLE DSH_HOST_BRIDGE_URL DSH_HOST_BRIDGE_TOKEN; node --expose-internals --expose-gc /tmp/dsh-session-lease-test.mjs' session-lease-native > "$WORK/session-native.log" 2>&1 || native_status=$?
cat "$WORK/session-native.log"
[ "$native_status" = 0 ] || exit "$native_status"
# The emulator currently returns host status 0 even for a guest assertion
# failure. Require the exact complete suite receipt as well as strict host
# wait/deadline/pipe cleanup; neither result alone can establish a pass.
python3 "$HERE/check-session-lease-guest.py" --result "$GUEST_RESULT" --output "$WORK/session-native.log"
[ "$GUEST_FAILURES" = 0 ]
echo 'SESSION_LEASE_GUEST_RUNNER_COMPLETED=1'
