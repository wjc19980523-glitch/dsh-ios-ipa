#!/usr/bin/env bash
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
WORK="${WORK:-$(mktemp -d "$ROOT/build/web-fetch-guest.XXXXXX")}"
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
INSTALL_COMMAND="$(python3 "$HERE/web-fetch-prepare.py" --output "$WORK/web-fetch-installer.mjs")"
install_status=0
guest "$INSTALL_COMMAND" web-fetch-install "$WORK/web-fetch-installer.mjs" > "$WORK/web-install.log" 2>&1 || install_status=$?
cat "$WORK/web-install.log"
[ "$install_status" = 0 ] || exit "$install_status"
grep -qx 'WEB_FETCH_PATCH_INSTALLED' "$WORK/web-install.log" || { echo 'web fetch install did not complete' >&2; exit 1; }
native_status=0
guest 'unset DSH_SESSION_LIFECYCLE DSH_HOST_BRIDGE_URL DSH_HOST_BRIDGE_TOKEN; export DSH_WEB_GUEST=1 NODE_EXTRA_CA_CERTS=/tmp/dsh-web-test/tests/fixtures/web-transport/test-cert.pem DSH_WEB_FETCH_SOURCE=/tmp/dsh-web-test/original-web-provider.js DSH_IPADDR_SOURCE=/usr/local/lib/node_modules/ipaddr.js/lib/ipaddr.js; node --expose-internals /tmp/dsh-web-test/tests/web-fetch-transport-test.mjs' web-fetch-native > "$WORK/web-native.log" 2>&1 || native_status=$?
cat "$WORK/web-native.log"
[ "$native_status" = 0 ] || exit "$native_status"
python3 "$HERE/check-web-fetch-guest.py" --result "$GUEST_RESULT" --output "$WORK/web-native.log"
[ "$GUEST_FAILURES" = 0 ]
echo 'WEB_FETCH_GUEST_RUNNER_COMPLETED=1'
