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
