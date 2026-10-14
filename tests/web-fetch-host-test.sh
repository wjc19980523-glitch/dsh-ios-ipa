#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TARBALL="${1:-$ROOT/build/root.tar.gz}"
WORK="${WORK:-$(mktemp -d "$ROOT/build/web-fetch-host.XXXXXX")}"
python3 "$HERE/web-fetch-prepare.py" --tarball "$TARBALL" --extract-fixtures "$WORK"
python3 "$HERE/web-fetch-prepare-test.py" --original "$WORK/web-provider.js"
export DSH_WEB_FETCH_SOURCE="$WORK/web-provider.js" DSH_IPADDR_SOURCE="$WORK/ipaddr.cjs"
export NODE_EXTRA_CA_CERTS="$HERE/fixtures/web-transport/test-cert.pem"
node --jitless "$HERE/web-fetch-transport-test.mjs"
