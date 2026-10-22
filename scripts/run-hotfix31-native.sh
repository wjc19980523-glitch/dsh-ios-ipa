#!/usr/bin/env bash
# Only the two existing P0 upgrade tests, on a disposable CI-owned simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/HotfixResults hotfix-evidence
xcrun simctl list runtimes --json > build/HotfixResults/runtimes.json
xcrun simctl list devicetypes --json > build/HotfixResults/devices.json
python3 - <<'PY' > build/HotfixResults/selection.txt
import json
from pathlib import Path
runtimes = [r for r in json.loads(Path('build/HotfixResults/runtimes.json').read_text())['runtimes']
            if r.get('isAvailable') and '.iOS-' in r['identifier']]
devices = [d for d in json.loads(Path('build/HotfixResults/devices.json').read_text())['devicetypes']
           if d['name'].startswith('iPad')]
assert runtimes and devices
print(next((d for d in devices if 'iPad-Pro-11-inch-M4-' in d['identifier']), devices[-1])['identifier'])
print(max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
SIM_ID="$(xcrun simctl create "DSH-Hotfix31-${GITHUB_RUN_ID}-$$" \
  "$(sed -n '1p' build/HotfixResults/selection.txt)" "$(sed -n '2p' build/HotfixResults/selection.txt)")"
cleanup() {
  xcrun simctl shutdown "$SIM_ID" >/dev/null 2>&1 || true
  xcrun simctl delete "$SIM_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$SIM_ID"
xcrun simctl bootstatus "$SIM_ID" -b
xcodebuild -project DSH.xcodeproj -scheme DSH -configuration Release \
  -destination "platform=iOS Simulator,id=$SIM_ID" -destination-timeout 120 \
  -derivedDataPath "$PWD/build/HotfixDerived-Sim" -resultBundlePath "$PWD/build/HotfixResults/upgrade.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 \
  -only-testing:DSHTests/DSHSessionLifecycleInstallerTests/testActualBuild30TrackingUpgradeChangesOnlyControllerAndPreservesUserData \
  -only-testing:DSHTests/DSHSessionLifecycleInstallerTests/testActualBuild30TrackingUpgradeRejectsUnknownControllerWithoutWrites \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  COMPILER_INDEX_STORE_ENABLE=NO test 2>&1 | tee hotfix-evidence/native-upgrade.log
python3 scripts/report-xctests.py --xcresult build/HotfixResults/upgrade.xcresult \
  --label hotfix31-upgrade --json-output hotfix-evidence/xctest-counts.json
python3 scripts/check-hotfix31.py native --input build/HotfixResults/upgrade.xcresult \
  --output hotfix-evidence/native-upgrade.json
