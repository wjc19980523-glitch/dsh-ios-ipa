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
INSTALL_COMMAND="$(python3 "$HERE/session-lease-prepare.py" --command --include-guest-test)"
guest "$INSTALL_COMMAND" session-lease-install
guest 'unset DSH_SESSION_LIFECYCLE DSH_HOST_BRIDGE_URL DSH_HOST_BRIDGE_TOKEN; node --expose-internals --expose-gc /tmp/dsh-session-lease-test.mjs' session-lease-native
[ "$GUEST_FAILURES" = 0 ]
echo 'SESSION_LEASE_GUEST_RUNNER_COMPLETED=1'
