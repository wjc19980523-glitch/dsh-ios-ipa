#!/usr/bin/env bash
# Build the guest root filesystem bundled into the DSH iOS app:
#   Alpine 3.21 (aarch64) + Node.js 22 + @deepseek-ai/dsh (+ rebuilt node-pty)
#
# Everything guest-side runs inside the iSH-ARM64 CLI emulator on macOS, so the
# result is byte-for-byte what the app boots. Output: build/root.tar.gz
#
# Usage: scripts/build-rootfs.sh [--keep-work]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ISH_SRC="${ISH_SRC:-$ROOT/ish-arm64}"
ISH_BUILD="${ISH_BUILD:-$ISH_SRC/build-arm64-release}"
WORK="${WORK:-$ROOT/build/rootfs-work}"
OUT="${OUT:-$ROOT/build/root.tar.gz}"

ALPINE_VER=3.21
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VER}.0-aarch64.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/aarch64/${ALPINE_TARBALL}"
# Pinned dsh release; bump together with package-lock.json under rootfs/staging.
#
# 0.2.0-rc.2 rather than 0.1.0-rc.7: the 0.1.x tree ships neither
# @deepseek-ai/dsh-client-locale (the shipped zh/en GUI) nor the corrected
# `deepseek-flash` model id -- 0.1.x advertises the retired `deepseek-v4-flash`,
# which DeepSeek still accepts but routes to the V4.1 model without saying so.
# 0.2.x keeps `cordis.patch.yml` as the profile patch layer, so the guest's
# existing home layout and settings survive the upgrade.
DSH_VERSION="${DSH_VERSION:-0.2.0-rc.2}"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The guest node prints this warning on every start; strip it from build logs.
# `sed` deliberately returns success for empty input while `pipefail` still
# propagates a failing emulator command.  The old `grep ... || true` hid guest
# failures and could export a corrupt image as a successful build.
filter() { sed '/expose_wasm/d'; }

ish() {
    # ish <script-on-stdin>; runs /bin/sh inside the fakefs
    "$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh 2>&1 | filter
}

[ -x "$ISH_BUILD/ish" ] || die "iSH CLI not built. Run: (cd $ISH_SRC && meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release && ninja -C build-arm64-release)"
[ -x "$ISH_BUILD/tools/fakefsify" ] || die "fakefsify not built in $ISH_BUILD/tools"
command -v npm >/dev/null || die "npm is required on the host"

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

log "Alpine minirootfs"
[ -f "$ALPINE_TARBALL" ] || curl -fsSL -o "$ALPINE_TARBALL" "$ALPINE_URL"

log "Create fakefs"
rm -rf fakefs
"$ISH_BUILD/tools/fakefsify" "$ALPINE_TARBALL" fakefs

log "Stage dsh node_modules on the host (linux/arm64/musl)"
rm -rf stage && mkdir stage
cp "$ROOT/rootfs/staging/package.json" stage/
[ -f "$ROOT/rootfs/staging/package-lock.json" ] && cp "$ROOT/rootfs/staging/package-lock.json" stage/
# `npm ci` installs strictly from package-lock.json and fails outright when the
# lockfile disagrees with package.json.  That failure used to be swallowed by a
# `|| npm install @deepseek-ai/dsh@${DSH_VERSION}` fallback, which silently
# produced an unpinned tree: bumping the version here without regenerating the
# lockfile gave a guest that reported the new `dsh --version` while every
# transitive dependency -- including the native koffi/sharp builds -- still came
# from the old tree.  On 0.2.0-rc.2 that mismatch SIGILL'd inside the emulator at
# guest startup, and the 27 downstream assertions only ever reported the symptom.
#
# Keep the fallback (offline/registry-flake recovery needs it) but make it loud
# and verify the result, so a stale lockfile can never pass silently again.
if ( cd stage && npm ci --os=linux --cpu=arm64 --libc=musl --ignore-scripts --no-audit --no-fund 2>&1 | tail -3 ); then
    :
else
    echo "WARNING: 'npm ci' failed; falling back to an unpinned 'npm install'." >&2
    echo "WARNING: if the cause was a stale package-lock.json, regenerate it:" >&2
    echo "WARNING:   (cd rootfs/staging && npm install --package-lock-only --os=linux --cpu=arm64 --libc=musl --ignore-scripts)" >&2
    npm install "@deepseek-ai/dsh@${DSH_VERSION}" --os=linux --cpu=arm64 --libc=musl --ignore-scripts --no-audit --no-fund \
        --prefix "$WORK/stage" 2>&1 | tail -3
fi
# Persist whatever tree we ended up with back into the repo pin.  A successful
# `npm ci` leaves the lockfile byte-identical; the fallback rewrites it, which is
# how a stale pin gets corrected -- review the diff, then commit it.
[ -f stage/package-lock.json ] && cp stage/package-lock.json "$ROOT/rootfs/staging/package-lock.json"

# The installed tree must actually advertise the version we pinned, and must
# carry the four native modules the guest selftest loads.  Checking here turns a
# guest-side SIGILL into a host-side build failure with a readable reason.
installed_dsh_version=$(node -p "require('./stage/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || true)
if [ "$installed_dsh_version" != "$DSH_VERSION" ]; then
    echo "staged dsh is '$installed_dsh_version' but DSH_VERSION is '$DSH_VERSION' -- the lockfile is stale" >&2
    exit 1
fi
for native_module in koffi node-pty sharp; do
    [ -d "stage/node_modules/$native_module" ] || {
        echo "staged tree is missing the native module '$native_module'" >&2
        exit 1
    }
done

# koffi must carry the libc probe, or the guest SIGILLs on the first require.
#
# dsh 0.2.0-rc.2 pins `"koffi": "3.1.1"`, and 3.1.1's Linux loader requires
# ./linux_arm64/koffi.node (the GLIBC binary) first and only falls back to
# ./musl_arm64/koffi.node in a catch block.  Under the iSH JIT that load is a
# hard `illegal instruction at 0x69850: insn=0x00000000` -- a SIGILL is a
# process signal, not a JS exception, so the catch never runs and the guest dies
# inside `require("koffi")` before anything else starts.  dsh 0.1.x declared
# `"koffi": "^3.1.0"` and so resolved 3.1.5, which reads the ELF PT_INTERP and
# picks ld-musl-* correctly; the exact pin in 0.2.x is what regressed.
#
# rootfs/staging/package.json therefore overrides koffi to 3.1.6.  Assert both
# halves of that here: the version, and the probe actually being in the shipped
# loader.  Without this the failure only shows up as a guest crash.
koffi_version=$(node -p "require('./stage/node_modules/koffi/package.json').version" 2>/dev/null || true)
if [ "$koffi_version" = "3.1.1" ]; then
    echo "staged koffi is 3.1.1, whose loader tries the glibc binary first and" >&2
    echo "SIGILLs under the iSH JIT -- rootfs/staging/package.json must override it" >&2
    exit 1
fi
koffi_loader="stage/node_modules/@koromix/koffi-linux-arm64/index.js"
[ -f "$koffi_loader" ] || {
    echo "missing $koffi_loader" >&2
    exit 1
}
grep -q 'ld-musl-' "$koffi_loader" || {
    echo "staged koffi ($koffi_version) has no libc probe in $koffi_loader;" >&2
    echo "it would load the glibc binary from Alpine and SIGILL" >&2
    exit 1
}
log "staged dsh $installed_dsh_version with native modules present (koffi $koffi_version, libc probe OK)"

# ---------------------------------------------------------------------------
# Patch dsh-app-boot so its runtime module-resolution interception can reach
# Node's internals without the node-addon-require-builtin native addon.
#
# Why: `internalModules()` in @deepseek-ai/dsh-app-boot (lib/index.js and the
# duplicate in lib/worker/profile-resolution-bootstrap.js) called
# `requireBuiltin()` unconditionally.  Up to node-addon-require-builtin 0.1.5
# that was harmless on Alpine because the package shipped no linux-arm64-musl
# binary and failed closed into JS.  0.1.9 (pulled in by dsh 0.2.0-rc.2) does
# ship one, so the addon loads `prebuilt/linux-arm64-musl-napi-v9.node` inside
# the iSH JIT, which cannot execute it: the guest dies with
# `illegal instruction at 0x69850: insn=0x00000000` before the web UI ever
# answers, cascading into ~27 failed assertions.
#
# Disabling the optional package (NARB_DISABLE_OPTIONAL_PACKAGE=1) is NOT a fix:
# loadEntry() then falls through to a local-build search and throws
# `No usable native binding found`, turning the SIGILL into an uncaught
# module-load failure on the boot path -- verified on both hosts.
#
# The supported alternative already exists and is already in use: dsh-serve
# launches node with `--expose-internals`, which makes `require("internal/...")`
# work directly.  @deepseek-ai/cordis-plugin-loader has always done exactly this
# two-step lookup.  We apply the same lookup to app-boot: prefer the flag, keep
# the addon as the fallback so builds without the flag are unaffected.
#
# The replacement is textually exact and version-checked: if an upstream release
# changes these lines the build fails here, loudly, instead of shipping a guest
# that SIGILLs.
# ---------------------------------------------------------------------------
log "Patch dsh-app-boot to prefer --expose-internals over the native addon"
app_boot_dir="stage/node_modules/@deepseek-ai/dsh-app-boot"
[ -d "$app_boot_dir" ] || die "dsh-app-boot is not in the staged tree"
for app_boot_file in "$app_boot_dir/lib/index.js" "$app_boot_dir/lib/worker/profile-resolution-bootstrap.js"; do
    [ -f "$app_boot_file" ] || die "$app_boot_file is missing"
    node - "$app_boot_file" <<'PATCHEOF'
const fs = require("fs");
const file = process.argv[2];
const original = fs.readFileSync(file, "utf8");
const target = [
	'	const addon = createRequire(import.meta.url)("node-addon-require-builtin");',
	'	const esmModule = addon.requireBuiltin("internal/modules/esm/loader");',
	'	const cjsModule = addon.requireBuiltin("internal/modules/cjs/loader");',
	'	const cjsHelpers = addon.requireBuiltin("internal/modules/helpers");',
	'	const esmUtils = addon.requireBuiltin("internal/modules/esm/utils");',
	'	const esmResolve = addon.requireBuiltin("internal/modules/esm/resolve");',
].join("\n");
const marker = "// dsh-ios: prefer --expose-internals";
if (original.includes(marker)) {
	process.stdout.write("already patched: " + file + "\n");
	process.exit(0);
}
if (!original.includes(target)) {
	process.stderr.write(
		"cannot patch " + file + ": the internalModules() body did not match.\n" +
		"Upstream changed it; re-derive the patch before shipping.\n");
	process.exit(1);
}
const replacement = [
	'	// dsh-ios: prefer --expose-internals, then fall back to the native addon.',
	'	// The prebuilt node-addon-require-builtin musl binary cannot execute under',
	'	// the iSH JIT, so the flag is the only working path inside the guest.',
	'	const loadInternal = (id) => {',
	'		if (process.execArgv.includes("--expose-internals")) {',
	'			try { return createRequire(import.meta.url)(id); } catch {}',
	'		}',
	'		return createRequire(import.meta.url)("node-addon-require-builtin").requireBuiltin(id);',
	'	};',
	'	const esmModule = loadInternal("internal/modules/esm/loader");',
	'	const cjsModule = loadInternal("internal/modules/cjs/loader");',
	'	const cjsHelpers = loadInternal("internal/modules/helpers");',
	'	const esmUtils = loadInternal("internal/modules/esm/utils");',
	'	const esmResolve = loadInternal("internal/modules/esm/resolve");',
].join("\n");
fs.writeFileSync(file, original.replace(target, replacement));
process.stdout.write("patched: " + file + "\n");
PATCHEOF
done
# Prove the patched files still parse and the marker really landed.
for app_boot_file in "$app_boot_dir/lib/index.js" "$app_boot_dir/lib/worker/profile-resolution-bootstrap.js"; do
    grep -q "dsh-ios: prefer --expose-internals" "$app_boot_file" \
        || die "patch marker missing from $app_boot_file"
    node --input-type=module --check < "$app_boot_file" \
        || die "$app_boot_file does not parse after patching"
done
# The unconditional addon call must be gone from both copies.
grep -q 'addon.requireBuiltin("internal/modules/esm/loader")' "$app_boot_dir/lib/index.js" \
    && die "lib/index.js still calls requireBuiltin unconditionally"
grep -q 'addon.requireBuiltin("internal/modules/esm/loader")' "$app_boot_dir/lib/worker/profile-resolution-bootstrap.js" \
    && die "profile-resolution-bootstrap.js still calls requireBuiltin unconditionally"
log "dsh-app-boot patched (flag first, addon as fallback)"

log "Guest phase 1: packages"
ish <<'EOF'
set -e
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
apk update >/dev/null
apk add --no-progress nodejs npm nodejs-dev python3 make g++ bash git curl openssh-client ca-certificates 2>&1 | tail -1
node -v; npm -v
EOF

log "Guest phase 2: install node_modules + polyfills + overlay"
# Assemble one payload tree rooted at / (staged node_modules, the iSH
# node polyfills, our overlay) and stream it into the guest in a single pass.
rm -rf payload && mkdir -p payload/usr/local/lib payload/lib
mv stage/node_modules payload/usr/local/lib/node_modules
# npm retains every optional sharp binary named in the lockfile even when the
# target is pinned to linux/arm64/musl.  The glibc build cannot load on Alpine,
# and the wasm fallback cannot run under DSH's jitless Node.  Keep only the
# musl/arm64 pair that sharp actually selects in the guest.  Also strip macOS
# AppleDouble files before they become tens of thousands of fakefs entries.
rm -rf payload/usr/local/lib/node_modules/@img/sharp-linux-arm64 \
       payload/usr/local/lib/node_modules/@img/sharp-libvips-linux-arm64 \
       payload/usr/local/lib/node_modules/@img/sharp-wasm32
cp "$ISH_SRC"/app/RootfsPatch.bundle/files/lib/*.js payload/lib/
# Record the overlay version so the app does not re-apply (and downgrade) the
# same RootfsPatch files on first launch.
overlay_ver=$(/usr/libexec/PlistBuddy -c 'Print :version' "$ISH_SRC/app/RootfsPatch.bundle/manifest.plist")
mkdir -p payload/ish && printf '%s\n' "$overlay_ver" > payload/ish/overlay-version
cp -R "$ROOT/rootfs/overlay/." payload/
find payload -name '._*' -delete
# BSD tar otherwise serialises extended attributes as AppleDouble `._*` files
# when this payload is unpacked by the Linux guest.
COPYFILE_DISABLE=1 tar czf payload.tgz -C payload .
"$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c 'cd / && tar xzf -' < payload.tgz 2>&1 | filter

log "Guest phase 3: node-pty rebuild for musl, profile, cleanup"
ish <<EOF
set -e
export HOME=/root
chmod +x /usr/local/bin/* /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js
ln -sf ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh
cd /usr/local/lib/node_modules/node-pty
rm -rf build prebuilds
npx --yes node-gyp rebuild --nodedir=/usr 2>&1 | tail -1
test -f build/Release/pty.node
# Pre-create the web profile so first launch on device does no scaffolding,
# then drop in our patch layer.
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config >/dev/null
install -m 0644 /usr/local/share/dsh/cordis.patch.yml /root/.dsh/profiles/web/cordis.patch.yml
# Seed the GUI language so a fresh install opens in Simplified Chinese instead of
# following WKWebView's en-US navigator languages. dsh-client-locale validates
# this against a BCP 47 pattern and treats an absent value as "ask the browser".
cat >> /root/.dsh/profiles/web/cordis.patch.yml <<'PATCHEOF'

# Seeded by build-rootfs.sh. Changing the language in Settings rewrites this
# section; deleting it falls back to the browser's languages.
- id: locale
  config:
    preference: zh
PATCHEOF
# Home-level layer: applies to every profile (see rootfs/overlay/.../home.patch.yml).
install -m 0644 /usr/local/share/dsh/home.patch.yml /root/.dsh/cordis.patch.yml
mkdir -p /root/workspace
# Slim down: build tooling is only needed for node-pty.
apk del --no-progress nodejs-dev python3 make g++ >/dev/null 2>&1 || true
apk add --no-progress libstdc++ libgcc >/dev/null
rm -rf /root/.npm /root/.cache /var/cache/apk/* /tmp/* /usr/local/lib/node_modules/node-pty/build/Release/obj.target
echo "guest node: \$(node -v), dsh: \$(dsh --version)"
du -sh /usr/local/lib/node_modules /usr/lib/node_modules 2>/dev/null
EOF

log "Export root.tar.gz"
rm -f "$OUT"
"$ISH_BUILD/tools/unfakefsify" fakefs "$OUT"
ls -lh "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"

if [ "${1:-}" != "--keep-work" ]; then
    rm -rf stage payload payload.tgz
fi
log "Done: $OUT"
