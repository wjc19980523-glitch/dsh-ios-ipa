#!/usr/bin/env bash
# Integration test for build/root.tar.gz: import it exactly like the app does
# (fakefsify), then boot dsh inside the iSH-ARM64 CLI emulator and probe it
# from the macOS host over loopback.
#
# Usage: tests/rootfs-test.sh [path/to/root.tar.gz]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ISH_SRC="${ISH_SRC:-$ROOT/ish-arm64}"
ISH_BUILD="${ISH_BUILD:-$ISH_SRC/build-arm64-release}"
TARBALL="${1:-$ROOT/build/root.tar.gz}"
WORK="${WORK:-$ROOT/build/rootfs-test}"
PORT="${DSH_TEST_PORT:-3181}"
MOCK_PORT="${DSH_MOCK_PORT:-3199}"
BRIDGE_PORT="${DSH_BRIDGE_PORT:-3197}"
# dsh 0.2.x composes its web plugin graph before binding and takes ~180s to
# serve on this emulated CPU (0.1.x managed it in ~30s), so the old 300s left
# little room for a loaded runner.
#
# 600s is a *guard against a false negative*, not a completion criterion, and
# not a performance budget: a run that only passes because the ceiling is high
# has taught us nothing about the cold start. The wait loop reports the phase
# boundaries it actually observed (see "phased boot" below).
BOOT_TIMEOUT="${DSH_BOOT_TIMEOUT:-600}"
# dsh prints its serve announcement and then keeps running in the foreground
# with nothing else to say. Reaching that line means the boot is over; waiting
# out the remaining BOOT_TIMEOUT seconds would be dead time (it cost 420s in the
# run that first exposed this). So the loop gives up early on a log that has
# both announced its URL and stopped growing for this many consecutive seconds.
SERVE_IDLE_GRACE="${DSH_SERVE_IDLE_GRACE:-10}"
GUEST_TIMEOUT="${DSH_GUEST_TIMEOUT:-90}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
# check <name> <command...>: runs the command (no eval), records the result
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
filter() { sed '/expose_wasm/d'; }
timed() {
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$@"
    else
        perl -e '$seconds = shift; alarm $seconds; exec @ARGV' "$@"
    fi
}
# A guest process that starts while the previous one is still tearing down can
# lose the fakefs lock and print nothing; every command here has output, so
# an empty result means "try again". A broken guest must not hang the release
# gate forever, so each attempt has a hard deadline.
guest() {
    local out
    for _ in 1 2; do
        out="$(timed "$GUEST_TIMEOUT" "$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c "$1" 2>&1 | filter)"
        [ -n "$out" ] && break
        sleep 1
    done
    printf '%s\n' "$out"
}

[ -f "$TARBALL" ] || { echo "missing $TARBALL (run scripts/build-rootfs.sh)"; exit 2; }
[ -x "$ISH_BUILD/ish" ] || { echo "iSH CLI not built"; exit 2; }
if curl -fs -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    echo "port $PORT is already in use on the host; set DSH_TEST_PORT"; exit 2
fi

cleanup() {
    pkill -f "$ISH_BUILD/ish -f $WORK/fakefs" 2>/dev/null || true
    for pid in "${MOCK_PID:-}" "${STUB_PID:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
    true
}
trap cleanup EXIT

echo "== import $TARBALL"
rm -rf "$WORK" && mkdir -p "$WORK"
"$ISH_BUILD/tools/fakefsify" "$TARBALL" "$WORK/fakefs"
check "root.tar.gz imports via fakefsify" test -f "$WORK/fakefs/meta.db"

echo "== guest sanity"
guest 'node -v; dsh --version; dsh-selftest' > "$WORK/sanity.txt"
sed 's/^/     /' "$WORK/sanity.txt"
check "node >= 22.19 in guest" grep -Eq '^v(22\.(19|[2-9][0-9])|2[3-9]|[3-9][0-9])' "$WORK/sanity.txt"
# 0.2.x, not 0.1.x: only 0.2.x ships dsh-client-locale (the zh GUI) and the
# corrected `deepseek-flash` model id. See scripts/build-rootfs.sh.
check "dsh 0.2.x in guest"      grep -Eq '^0\.2\.' "$WORK/sanity.txt"
# Exact match against the pin, not just the major line.  A stale
# rootfs/staging/package-lock.json makes `npm ci` fail, and the build script's
# `npm install` fallback once installed 0.2.0-rc.2's top-level package over a
# 0.1.0-rc.7 dependency tree: `dsh --version` looked right while koffi/sharp
# stayed old, and the mismatch SIGILL'd in the emulator.  Comparing the full
# string catches any future recurrence of a partially-upgraded tree.
expected_dsh_version="$(sed -n 's/^DSH_VERSION="\${DSH_VERSION:-\(.*\)}"$/\1/p' "$ROOT/scripts/build-rootfs.sh")"
check "guest dsh matches the pinned DSH_VERSION ($expected_dsh_version)" \
      grep -Fqx "$expected_dsh_version" "$WORK/sanity.txt"
# The four native modules dsh-selftest loads must be present as installed
# packages, independently of whether the selftest got far enough to prove it.
for native_module in koffi node-pty sharp; do
    check "native module $native_module is staged" \
          test -d "$WORK/fakefs/data/usr/local/lib/node_modules/$native_module"
done
# koffi must ship the libc probe.  dsh 0.2.0-rc.2 pins koffi 3.1.1, whose Linux
# loader requires the GLIBC binary first and only falls back to the musl one from
# a catch block -- but a SIGILL is a process signal, not a JS exception, so the
# fallback never runs and `require("koffi")` kills the guest at
# `illegal instruction at 0x69850`.  rootfs/staging/package.json overrides it to
# 3.1.6, which reads the ELF interpreter and chooses correctly.  Assert on the
# staged loader itself so the regression cannot come back silently.
koffi_loader="$WORK/fakefs/data/usr/local/lib/node_modules/@koromix/koffi-linux-arm64/index.js"
check "koffi loader probes libc instead of assuming glibc" \
      grep -q 'ld-musl-' "$koffi_loader"
koffi_version="$(node -p "require('$WORK/fakefs/data/usr/local/lib/node_modules/koffi/package.json').version" 2>/dev/null || true)"
check "koffi is not the 3.1.1 regression ($koffi_version)" test "$koffi_version" != "3.1.1"
check "dsh-selftest passes"     grep -q 'SELFTEST OK' "$WORK/sanity.txt"
# The 0.2.x boot path installs a runtime module-resolution interception whose
# original code called the node-addon-require-builtin native addon
# unconditionally.  On linux-arm64-musl that addon loads a binary the iSH JIT
# cannot execute (`illegal instruction at 0x69850`), killing the guest before the
# web UI answered.  build-rootfs.sh patches dsh-app-boot to prefer
# --expose-internals; these assertions prove the patch reached the image.
#
# Assert on the staged file too, not only on the selftest output, so a guest that
# dies before printing still reports the real cause as a failure.
check "dsh-app-boot patch applied (index.js)" \
      grep -q 'dsh-ios: prefer --expose-internals' \
      "$WORK/fakefs/data/usr/local/lib/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js"
check "dsh-app-boot patch applied (profile-resolution-bootstrap.js)" \
      grep -q 'dsh-ios: prefer --expose-internals' \
      "$WORK/fakefs/data/usr/local/lib/node_modules/@deepseek-ai/dsh-app-boot/lib/worker/profile-resolution-bootstrap.js"
check "dsh-app-boot does not call requireBuiltin unconditionally" \
      bash -c "! grep -q 'addon.requireBuiltin(\"internal/modules/esm/loader\")' \
               '$WORK/fakefs/data/usr/local/lib/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js'"
check "expose-internals module loader reachable in guest" \
      grep -q 'expose-internals exposes the module loader' "$WORK/sanity.txt"
check "sharp keeps musl arm64 runtime" test -d "$WORK/fakefs/data/usr/local/lib/node_modules/@img/sharp-linuxmusl-arm64"
check "sharp drops unusable glibc runtime" test ! -e "$WORK/fakefs/data/usr/local/lib/node_modules/@img/sharp-linux-arm64"
check "sharp drops unusable wasm fallback" test ! -e "$WORK/fakefs/data/usr/local/lib/node_modules/@img/sharp-wasm32"
if find "$WORK/fakefs/data" -name '._*' -print -quit | grep -q .; then
    bad "rootfs contains no macOS AppleDouble files"
else
    ok "rootfs contains no macOS AppleDouble files"
fi

echo "== profile composition"
guest 'export HOME=/root; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config' > "$WORK/config.yml"
grep -A4 '^- id: sandbox-policy' "$WORK/config.yml" > "$WORK/sandbox-row.yml"
check "sandbox-policy patched to danger-full-access" grep -q 'danger-full-access' "$WORK/sandbox-row.yml"
# HMR is what needs --expose-internals, so its presence proves the launch flag
# reaches the profile. dsh 0.2.x renamed the plugin: `cordis-plugin-hmr` is the
# 0.1.x name and no longer appears in the composed web profile.
check "hmr row present (needs --expose-internals)"    grep -q 'dsh-client-hmr' "$WORK/config.yml"

# The GUI language is seeded in the image so a fresh install opens in Simplified
# Chinese rather than following WKWebView's en-US navigator languages. Assert on
# the composed config, not just the patch file, so a silently-rejected locale
# section is caught here instead of on a device.
check "locale row composed from the profile patch"   grep -q '^- id: locale' "$WORK/config.yml"
check "locale preference is zh"                      grep -A3 '^- id: locale' "$WORK/config.yml" | grep -q 'preference: zh'
check "locale plugin shipped (zh GUI available)"     grep -q 'dsh-client-locale' "$WORK/config.yml"

# The retired id must not come back: DeepSeek still accepts `deepseek-v4-flash`
# and quietly serves V4.1 from it, so a regression here would look like it works.
if grep -q 'deepseek-v4-flash' "$WORK/config.yml"; then
    bad "model catalog advertises the retired deepseek-v4-flash id"
else
    ok "model catalog does not advertise the retired deepseek-v4-flash id"
fi
check "model catalog advertises deepseek-flash"      grep -q 'deepseek-flash' "$WORK/config.yml"
check "model catalog keeps deepseek-v4-pro"          grep -q 'deepseek-v4-pro' "$WORK/config.yml"

echo "== headless LLM round trip through mock DeepSeek server (SSE via fetch polyfill)"
node "$HERE/mock-deepseek.mjs" "$MOCK_PORT" > "$WORK/mock.log" 2>&1 &
MOCK_PID=$!
sleep 1
guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT; cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'Say hi.'" > "$WORK/headless.txt"
kill $MOCK_PID 2>/dev/null
sed 's/^/     /' "$WORK/headless.txt" | tail -3
check "headless answer streamed from mock server" grep -q 'MOCK-REPLY-7f3a' "$WORK/headless.txt"

echo "== host bridge: agent calls device_info through a stub bridge"
BRIDGE_TOKEN="stub-token-$$"
node "$HERE/stub-bridge.mjs" "$BRIDGE_PORT" "$BRIDGE_TOKEN" > "$WORK/stub-bridge.log" 2>&1 &
STUB_PID=$!
node "$HERE/mock-deepseek.mjs" "$MOCK_PORT" --tool device_info > "$WORK/mock-tool.log" 2>&1 &
MOCK_PID=$!
sleep 1
guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT \
       DSH_HOST_BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT DSH_HOST_BRIDGE_TOKEN=$BRIDGE_TOKEN; \
       cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'What device is this?'" > "$WORK/bridge-tool.txt"
sed 's/^/     /' "$WORK/bridge-tool.txt" | tail -3
check "device_info tool reached the bridge" grep -q '\[stub\] GET /v1/device' "$WORK/stub-bridge.log"
check "tool result reached the model"       grep -q 'model: iPad15,3' "$WORK/bridge-tool.txt"

# The calendar and reminders tools go through the same path.
for tool in calendar_query reminders_query; do
    kill $MOCK_PID 2>/dev/null
    node "$HERE/mock-deepseek.mjs" "$MOCK_PORT" --tool "$tool" > "$WORK/mock-$tool.log" 2>&1 &
    MOCK_PID=$!
    sleep 1
    guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT \
           DSH_HOST_BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT DSH_HOST_BRIDGE_TOKEN=$BRIDGE_TOKEN; \
           cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'What is on my schedule?'" > "$WORK/tool-$tool.txt"
    check "$tool reaches the bridge and renders a result" grep -qE 'Standup|Buy milk' "$WORK/tool-$tool.txt"
done

# health_query takes a required `metric`, and each one renders differently.
for metric_case in "activity:9312 steps" "heart_rate:avg 71" "sleep:asleep" "workouts:Running"; do
    metric="${metric_case%%:*}"; expected="${metric_case#*:}"
    kill $MOCK_PID 2>/dev/null
    node "$HERE/mock-deepseek.mjs" "$MOCK_PORT" --tool health_query --tool-args "{\"metric\":\"$metric\",\"days\":3}" > "$WORK/mock-health-$metric.log" 2>&1 &
    MOCK_PID=$!
    sleep 1
    guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT \
           DSH_HOST_BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT DSH_HOST_BRIDGE_TOKEN=$BRIDGE_TOKEN; \
           cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'How active have I been?'" > "$WORK/tool-health-$metric.txt"
    check "health_query $metric reaches the bridge and renders" grep -q "$expected" "$WORK/tool-health-$metric.txt"
done

# Every remaining bridge tool, each driven through a real agent turn. The
# arguments matter: the tools with required parameters must reach the route
# with them, and the renderers must turn each answer into something readable.
BRIDGE_TOOL_CASES=(
    "device_power|{}|thermalState: fair"
    "location_query|{}|±65 m"
    "contacts_search|{\"query\":\"ada\"}|Ada Lovelace"
    "notify|{\"title\":\"Done\"}|Notification sent"
    "calendar_create_event|{\"title\":\"Standup\",\"start\":\"2026-08-20 09:00\"}|Added.*Standup.*to Work"
    "reminders_create|{\"title\":\"Buy milk\"}|Added.*Buy milk.*to Home"
    "file_import|{}|picked.*notes[.]txt"
    "file_export|{\"name\":\"report.md\",\"base64\":\"aGVsbG8=\"}|Saved.*report[.]md"
    "photo_import|{}|picked.*IMG_0042"
    "share|{\"text\":\"hello there\"}|shared the text"
    "shortcut_run|{\"name\":\"Log Water\"}|Started the shortcut"
)
for bridge_case in "${BRIDGE_TOOL_CASES[@]}"; do
    tool="${bridge_case%%|*}"; rest="${bridge_case#*|}"
    args="${rest%%|*}"; expected="${rest#*|}"
    kill $MOCK_PID 2>/dev/null
    node "$HERE/mock-deepseek.mjs" "$MOCK_PORT" --tool "$tool" --tool-args "$args" > "$WORK/mock-$tool.log" 2>&1 &
    MOCK_PID=$!
    sleep 1
    guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT \
           DSH_HOST_BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT DSH_HOST_BRIDGE_TOKEN=$BRIDGE_TOKEN; \
           cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'Please do it.'" > "$WORK/tool-$tool.txt"
    check "$tool reaches the bridge and renders" grep -qE "$expected" "$WORK/tool-$tool.txt"
done

# A wrong token must fail loudly instead of silently returning nothing.
guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT \
       DSH_HOST_BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT DSH_HOST_BRIDGE_TOKEN=wrong-token; \
       cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'What device is this?'" > "$WORK/bridge-denied.txt"
check "wrong bridge token is refused" grep -q 'unauthorized' "$WORK/bridge-denied.txt"

# The same image must still work with no bridge at all (CLI, tests, macOS).
guest "export HOME=/root; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config" > "$WORK/config-nobridge.yml"
check "plugin loads without bridge environment" grep -q 'host-bridge' "$WORK/config-nobridge.yml"
kill $STUB_PID $MOCK_PID 2>/dev/null

echo "== boot dsh-serve on 127.0.0.1:$PORT (timeout ${BOOT_TIMEOUT}s)"
start=$(date +%s)
( "$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c "DSH_PORT=$PORT dsh-serve" 2>&1 | filter > "$WORK/dsh-serve.log" ) &
up=0
prev_bytes=0
server_noticed=0
served_at=""
# dsh 0.2.x serves the UI on a process-token URL: it prints
#   dsh web: http://127.0.0.1:PORT/?token=<43 chars>
# and refuses an unauthenticated GET. The old check curled the bare path with
# `-f`, so a healthy server looked dead and the suite failed after burning the
# whole timeout. Read the token out of the announcement instead, and keep the
# bare path as the fallback so an older guest that needs no token still passes.
serve_url=""
token=""
idle=0
for i in $(seq 1 "$BOOT_TIMEOUT"); do
    sleep 1
    if [ -z "$serve_url" ]; then
        serve_url=$(grep -o 'http://127\.0\.0\.1:[0-9]*/?token=[A-Za-z0-9_-]*' "$WORK/dsh-serve.log" 2>/dev/null | head -1)
        if [ -n "$serve_url" ]; then
            token="${serve_url#*token=}"
            # The launch token is a bearer credential for this guest's UI. It
            # must not travel into the CI artefact, the job summary, or an
            # issue. Replace it in the log the moment it has been parsed, and
            # keep it only in this shell.
            sed -i.bak 's/token=[A-Za-z0-9_-]*/token=<redacted>/g' "$WORK/dsh-serve.log" 2>/dev/null && rm -f "$WORK/dsh-serve.log.bak"
            server_noticed=$i
            served_at="$i"
            echo "     [${i}s] server announced its web URL on port $PORT (token captured, not printed)"
        fi
    fi
    target="${serve_url:-http://127.0.0.1:$PORT/}"
    if curl -fs -o "$WORK/index.html" "$target"; then up=1; served_at="$i"; break; fi
    # A heartbeat every 20s separates "the guest is slow" from "the guest is
    # stuck": if the byte count keeps moving, the boot is progressing and the
    # timeout is simply too tight for an emulated CPU; if it stops, the boot
    # deadlocked and the log's last line names where.
    if [ $((i % 20)) = 0 ]; then
        now_bytes=$(wc -c < "$WORK/dsh-serve.log" 2>/dev/null || echo 0)
        echo "     [${i}s] dsh-serve.log ${now_bytes} bytes ($([ "$now_bytes" = "$prev_bytes" ] && echo stalled || echo growing))"
        prev_bytes=$now_bytes
    fi
    # Once the server has announced its URL and the log has gone quiet, nothing
    # more is coming: dsh is serving and waiting on stdin. Stop burning the
    # clock. `$serve_url` being non-empty is what makes this safe — a log that
    # merely stopped growing without ever announcing is still a boot in
    # progress, and still gets the full BOOT_TIMEOUT.
    if [ -n "$serve_url" ] && [ "$i" -gt "$SERVE_IDLE_GRACE" ]; then
        idle=$((idle + 1))
        if [ "$idle" -ge "$SERVE_IDLE_GRACE" ]; then
            echo "     [${i}s] serving and idle for ${SERVE_IDLE_GRACE}s; stopping the wait early"
            break
        fi
    fi
done
elapsed=$(( $(date +%s) - start )) 2>/dev/null || elapsed=0
check "web UI reachable from host loopback (${elapsed}s)" test "$up" = 1
# Everything after this point needs the same token the check above used.
base_url="${serve_url:-http://127.0.0.1:$PORT/}"
if [ "$up" != 1 ]; then
    # The timeout burns five minutes, so surface why instead of making the next
    # run wait for it again. The serve log is short: dsh prints its boot
    # progress and usually the reason it never bound the port. The token is
    # stripped again here as a belt-and-braces measure: this dump and the log
    # file both end up in a downloadable artefact.
    echo "     --- dsh-serve.log (last 60 lines) ---"
    tail -60 "$WORK/dsh-serve.log" 2>/dev/null | sed -e 's/token=[A-Za-z0-9_-]*/token=<redacted>/g' -e 's/^/     /'
    echo "     --- end dsh-serve.log ---"
fi
check "index carries __DSH_BOOT__ manifest" grep -q '__DSH_BOOT__' "$WORK/index.html"
plugin_url=$(grep -o '/plugins/[^"]*client.js?rev=[0-9a-f]*' "$WORK/index.html" | head -1)
# The bundle route is relative to the origin, so re-attach the token.
token_qs="${base_url#*\?}"
bundle_url="http://127.0.0.1:$PORT$plugin_url"
[ "$token_qs" != "$base_url" ] && bundle_url="$bundle_url&$token_qs"
code=$(curl -s -o /dev/null -w '%{http_code}' "$bundle_url")
check "client plugin bundle served ($plugin_url -> $code)" test "$code" = 200
sleep 5
check "server still alive after 5s" curl -fs -o /dev/null "$base_url"
grep -Eq 'fatal|Error:' "$WORK/dsh-serve.log"; noerr=$?
check "no fatal error in dsh-serve log" test "$noerr" != 0

# An unauthenticated request must be refused. This is the contract the iOS side
# implements, and the reason a bare-origin "it returned a status" is not proof
# that the UI is being served.
unauth_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
check "unauthenticated request is refused with 401 (got $unauth_code)" test "$unauth_code" = 401
unauth_head=$(curl -s -I -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
check "unauthenticated HEAD is refused too (got $unauth_head)" test "$unauth_head" = 401

# Phased boot timings. The point is to separate the emulator's own cost from
# what dsh 0.2.x added, so a future regression has a number to move against
# instead of "it felt slower". `server_noticed` is the wall-clock second at
# which dsh 0.2.x printed its URL; everything before it is emulator + Node +
# plugin-graph cost, everything after is the HTTP round trip. The two numbers
# together are the cold start, and they must be reported, not just bounded.
if [ -n "$serve_url" ] || grep -q 'dsh web:' "$WORK/dsh-serve.log"; then
    echo "     --- phased boot (wall clock from launch) ---"
    echo "     announced the web URL at:  ${server_noticed}s"
    echo "     first served byte at:      ${served_at}s  (HTTP round trip $((${served_at:-0} - ${server_noticed:-0}))s)"
    echo "     total to first served byte:${elapsed}s"
    echo "     component split:"
    echo "       emulator + node + plugin graph  ${server_noticed}s"
    echo "       first HTTP response            $((${served_at:-0} - ${server_noticed:-0}))s"
    grep -E 'dsh web:|listening|plugin|ready' "$WORK/dsh-serve.log" 2>/dev/null | tail -8 | sed 's/^/       /'
    echo "     --- end phased boot ---"
fi
# The bound is a guard, so make it loud when it is the only thing that held.
if [ "$up" = 1 ] && [ "$served_at" -ge "$BOOT_TIMEOUT" ]; then
    echo "     note: only passed because BOOT_TIMEOUT was raised; treat as a"
    echo "           performance regression, not a green light."
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
