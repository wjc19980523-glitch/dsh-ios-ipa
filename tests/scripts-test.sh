#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fixture=$(mktemp /tmp/dsh-simulators.XXXXXX)
trap 'rm -f "$fixture"' EXIT

printf '%s\n' \
  '== Devices ==' \
  '-- iOS 26.0 --' \
  '    iPad Pro 13-inch (M5) (CB894F29-D83F-492A-8927-18D23BC76403) (Shutdown) ' \
  '    iPhone 17 Pro (3135C53E-C4EA-4D81-B488-6692757B524C) (Shutdown)' > "$fixture"

actual=$(DSH_SIMULATOR_LIST_FILE="$fixture" scripts/pick-simulator.sh)
[ "$actual" = 'iPad Pro 13-inch (M5)' ] || {
  echo "not ok: simulator parser returned '$actual'" >&2
  exit 1
}

printf 'ok  scripts: simulator names with parenthesized models\n'

target=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET = //p' app/AppDSH.xcconfig | tr -d ' ')
[ "$target" = '16.0' ] || {
  echo "not ok: deployment target is '$target', expected 16.0" >&2
  exit 1
}

generated_targets=$(grep -c "new_target(.*:ios, '16.0')" scripts/gen-xcode-project.rb)
[ "$generated_targets" = '3' ] || {
  echo "not ok: project generator does not keep all three targets on iOS 16" >&2
  exit 1
}

printf 'ok  scripts: app and generated test targets support iOS 16\n'

# A generated project is source in this repository. Re-running the generator
# must not rewrite random object identifiers or scheme blueprint identifiers.
ruby scripts/gen-xcode-project.rb >/dev/null
first_project=$(shasum -a 256 DSH.xcodeproj/project.pbxproj DSH.xcodeproj/xcshareddata/xcschemes/DSH.xcscheme)
ruby scripts/gen-xcode-project.rb >/dev/null
second_project=$(shasum -a 256 DSH.xcodeproj/project.pbxproj DSH.xcodeproj/xcshareddata/xcschemes/DSH.xcscheme)
[ "$first_project" = "$second_project" ] || {
  echo 'not ok: project generator output changes between identical runs' >&2
  exit 1
}

printf 'ok  scripts: Xcode project generation is reproducible\n'

bash -n scripts/release.sh
grep -q 'release_tag="v${version}-build${next_build}"' scripts/release.sh
grep -q 'release tag ${release_tag} already exists' scripts/release.sh
grep -q 'delivery_uuid' scripts/release.sh
grep -q 'ipa_sha256' scripts/release.sh

printf 'ok  scripts: release preflight and receipt recording are present\n'

node - <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync('docs/capabilities.json', 'utf8'));
const plugin = fs.readFileSync('rootfs/overlay/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js', 'utf8');
const app = fs.readdirSync('app').filter(f => f.endsWith('.m')).map(f => fs.readFileSync(`app/${f}`, 'utf8')).join('\n');
const tools = manifest.capabilities.flatMap(c => c.tools);
for (const tool of tools) {
  if (!plugin.includes(`name: "${tool}"`)) throw new Error(`manifest tool missing from plugin: ${tool}`);
}
for (const capability of manifest.capabilities) {
  if (!app.includes(`@"${capability.id}"`)) throw new Error(`manifest capability missing from app: ${capability.id}`);
}
if (new Set(tools).size !== tools.length) throw new Error('duplicate tool in capability manifest');
NODE

printf 'ok  scripts: capability manifest matches app and guest tools\n'

# The launch token is a bearer credential for the guest's web UI, and the CI
# job both prints and uploads the serve log. Redaction is a property of the
# pipeline, not of one call site, so assert it is wired in everywhere that can
# carry the line.
grep -q 'token=<redacted>' tests/rootfs-test.sh || {
  echo 'not ok: tests/rootfs-test.sh no longer redacts the launch token before it can reach the artefact' >&2
  exit 1
}
# The capture must wait for the whole 43-character token. A partially written
# announcement yields a short token, and then every request uses it: run
# 38061283295 failed with 000s that looked like an unreachable server while the
# server was serving fine.
grep -q 'raw_token}" -ge 43' tests/rootfs-test.sh || {
  echo 'not ok: the launch token is captured before all 43 characters have been written' >&2
  exit 1
}
# The redaction pattern must be anchored to the token. `token=[A-Za-z0-9_-]*`
# also matches the empty string, so a second pass turns an already-redacted line
# into `token=<redacted><redacted>`.
grep -qF 's/token=$token\$/token=<redacted>/g' tests/rootfs-test.sh || {
  echo 'not ok: the launch-token redaction is unanchored and is not idempotent' >&2
  exit 1
}
grep -q 'redactingTokenInLine' app/DSHLogBuffer.m || {
  echo 'not ok: DSHLogBuffer no longer strips launch tokens; they would reach the on-disk log and the diagnostics report' >&2
  exit 1
}
grep -q 'DSHHarnessAuth' app/DSHHarness.m || {
  echo 'not ok: DSHHarness no longer captures the launch token; dsh 0.2.x answers 401 to everything without it' >&2
  exit 1
}
grep -q 'DSHProbeOutcomeUnauthorized' app/DSHReadinessProbe.m || {
  echo 'not ok: DSHReadinessProbe no longer distinguishes a 401 from a served page' >&2
  exit 1
}

printf 'ok  scripts: launch-token authentication is wired through app, log and CI\n'

# The boot wait must not be a fixed sleep against the ceiling. A run that
# returns only because BOOT_TIMEOUT was raised proves nothing about the cold
# start, and the CI record must show the phase split, not just a bound.
grep -q 'SERVE_IDLE_GRACE' tests/rootfs-test.sh || {
  echo 'not ok: tests/rootfs-test.sh no longer stops waiting once the server is idle' >&2
  exit 1
}
grep -q 'served and idle for' tests/rootfs-test.sh || {
  echo 'not ok: the success-path early exit is no longer reported in the CI log' >&2
  exit 1
}
# The early exit must never fire while the fetch is still failing. Announcing
# the URL is not the same moment as accepting on the port: run 38067488275
# announced at 162s and was still refusing at 171s, and an exit gated on the
# announcement alone abandoned it and reported an unreachable server.
grep -q 'if \[ "\$up" = 1 \] && \[ -n "\$serve_url" \]' tests/rootfs-test.sh || {
  echo 'not ok: the early exit is no longer gated on a successful fetch; it can' >&2
  echo '        abandon a server that has announced but not yet accepted' >&2
  exit 1
}
grep -q 'component split:' tests/rootfs-test.sh || {
  echo 'not ok: the phased boot no longer reports emulator cost separately from the HTTP response' >&2
  exit 1
}
# The entry fetch must follow the 303 and store the auth cookie. dsh 0.2.x
# answers the token URL with 303 + Set-Cookie; `curl -fs` alone does not follow
# the redirect (`-f` only fails on >=400) and saved an empty 303 body as
# index.html, so `up` read 1 while the __DSH_BOOT__ manifest had nothing to
# read. `-L` follows, `-c`/`-b` carry the cookie.
grep -q 'curl -fsSL -c "\$WORK/cookies.txt" -b "\$WORK/cookies.txt"' tests/rootfs-test.sh || {
  echo 'not ok: the entry fetch no longer follows the 303 redirect and stores the auth cookie' >&2
  exit 1
}
# The failure path must report curl's exit code, not just http_code 000. 000
# means "no response"; the exit code is what distinguishes refused (7) from
# DNS (6) from timeout (28) from empty reply (52). Reporting 000 alone is how
# those get conflated and the fix aimed at the wrong layer.
grep -q 'probe_why="connection refused"' tests/rootfs-test.sh || {
  echo 'not ok: the failure probe no longer maps curl exit codes to a cause' >&2
  exit 1
}
grep -q 'announced the web URL at' tests/rootfs-test.sh || {
  echo 'not ok: the phased boot no longer reports when dsh announced its URL' >&2
  exit 1
}
grep -q 'only passed because BOOT_TIMEOUT was raised' tests/rootfs-test.sh || {
  echo 'not ok: a pass that only held because of the raised ceiling would go unreported' >&2
  exit 1
}
# The heartbeat must not call a healthy boot "stalled". dsh-serve writes nothing
# until it is finished, so a flat byte count is the normal state for the first
# ~160s; the label is what a reader uses to decide whether to investigate.
grep -q 'still booting: no output yet' tests/rootfs-test.sh || {
  echo 'not ok: the heartbeat no longer distinguishes a silent boot from a hang' >&2
  exit 1
}
# And the report must state the emulator-vs-Harness split, not just print two
# numbers and leave the conclusion to the reader.
grep -q 'is emulator + node + plugins' tests/rootfs-test.sh || {
  echo 'not ok: the phased boot no longer draws the emulator/Harness split conclusion' >&2
  exit 1
}

printf 'ok  scripts: the guest boot reports a phase split instead of only a timeout bound\n'

# The DSHTests target is only compiled by build-for-testing. `archive` builds the
# DSH target alone, so without this step the unit tests are shipped to CI
# without ever seeing a compiler -- which is exactly what happened to the
# authentication tests on their first three runs.
grep -q 'build-for-testing' .github/workflows/build-ipa.yml || {
  echo 'not ok: the workflow no longer builds the test bundle; DSHTests would stop being type-checked' >&2
  exit 1
}
grep -q '04b-build-for-testing.log' .github/workflows/build-ipa.yml || {
  echo 'not ok: the build-for-testing log is not captured' >&2
  exit 1
}

printf 'ok  scripts: the workflow type-checks the DSHTests bundle\n'

# DSHTests is hosted by the app and links against DSH.app/DSH, so it can only
# reach symbols the executable exports. Two symbol classes need two different
# mechanisms, and this block asserts both -- because using the wrong one does
# not fail loudly, it breaks the other class.
#
#   Objective-C classes  -> GCC_SYMBOLS_PRIVATE_EXTERN = NO
#   plain C globals      -> __attribute__((visibility("default"))) on the
#                           declaration (the DSH_EXPORTED macro)
#
# -Wl,-exported_symbol is the trap. One occurrence puts ld in allow-list mode:
# only the named symbols are exported and everything else is hidden. Adding two
# flags for the handshake constants silently dropped all 25 Objective-C classes
# from the export table, turning a 1-undefined-symbol link failure into a
# 30-undefined-symbol one (run 38066038064 -> run 38066579010).
grep -q 'GCC_SYMBOLS_PRIVATE_EXTERN *= *NO' app/AppDSH.xcconfig || {
  echo 'not ok: GCC_SYMBOLS_PRIVATE_EXTERN is no longer NO; the tests cannot see any DSH class' >&2
  exit 1
}
if grep -q -- '-Wl,-exported_symbol' app/AppDSH.xcconfig; then
  echo 'not ok: -Wl,-exported_symbol is back in AppDSH.xcconfig. It puts ld in' >&2
  echo '        allow-list mode and hides every symbol not named, including all' >&2
  echo '        Objective-C classes. Use DSH_EXPORTED instead.' >&2
  exit 1
fi

printf 'ok  scripts: symbol export uses the attribute, not the linker allow-list\n'

# Every plain C symbol the tests read must carry DSH_EXPORTED. Without it the
# symbol stays hidden even though GCC_SYMBOLS_PRIVATE_EXTERN is NO -- that
# setting does not reach plain C globals in an executable, which is how the
# first link failure happened.
grep -q 'DSHHarnessAuthCookiePrefix' app/DSHHarnessAuth.h || {
  echo 'not ok: DSHHarnessAuth no longer declares the cookie prefix the test server mimics' >&2
  exit 1
}

for sym in \
  DSHHarnessTokenQueryKey \
  DSHHarnessAuthCookiePrefix \
  DSHDisplayValue \
  DSHHarnessStateName \
  DSHHarnessStateDidChangeNotification \
  DSHLogBufferDidChangeNotification \
  DSHTurnWasInterruptedNotification
do
  if ! grep -q "DSH_EXPORTED[^;]*$sym" app/*.h; then
    echo "not ok: $sym is read by DSHTests but not marked DSH_EXPORTED; the link will fail" >&2
    exit 1
  fi
done

grep -q 'visibility("default")' app/DSHHarnessAuth.h || {
  echo 'not ok: the DSH_EXPORTED macro no longer expands to a visibility attribute' >&2
  exit 1
}

# DSHHarnessAuthCookiePrefix is the one C symbol the tests read that app code
# never touches -- nothing in app/ mentions it but its own definition. The app
# is linked -dead_strip, so it is removed before visibility can matter, and the
# link fails on that symbol alone. -u keeps it. Check both halves: the keep-flag
# and the absence of any in-app reader, which is what makes the flag necessary
# rather than decorative.
grep -q -- '-Wl,-u,_DSHHarnessAuthCookiePrefix' app/AppDSH.xcconfig || {
  echo 'not ok: DSHHarnessAuthCookiePrefix is no longer kept with -u; -dead_strip' >&2
  echo '        will drop it and DSHTests will fail to link' >&2
  exit 1
}
if grep -rq 'DSHHarnessAuthCookiePrefix' app/DSHHarnessAuth.m app/DSHHarness.m \
     app/DSHRootViewController.m app/DSHReadinessProbe.m 2>/dev/null; then
  # Only the definition line counts; anything else means app code reads it and
  # -u may no longer be needed. Not an error -- just worth knowing.
  refs=$(grep -rn 'DSHHarnessAuthCookiePrefix' app/*.m | grep -v 'const DSHHarnessAuthCookiePrefix' | wc -l)
  if [ "$refs" -gt 0 ]; then
    printf 'note: DSHHarnessAuthCookiePrefix now has %s in-app reader(s); -u may be redundant\n' "$refs"
  fi
fi

# Five headers define the macro. The guard is what keeps that from being a
# redefinition error the moment two of them are imported together.
grep -q 'ifndef DSH_EXPORTED' app/DSHHarnessAuth.h || {
  echo 'not ok: the DSH_EXPORTED macro is no longer guarded; five headers defining it would clash' >&2
  exit 1
}

printf 'ok  scripts: every C symbol the tests read is marked for export\n'
