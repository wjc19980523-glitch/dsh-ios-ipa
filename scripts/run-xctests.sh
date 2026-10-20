#!/usr/bin/env bash
# Execute units, real guest integration and UI tests separately. No IPA archive.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p cilogs build/TestResults

SIMULATOR_ID="${DSH_TEST_SIMULATOR_ID:-}"
OWNED_SIMULATORS=()
cleanup() {
  for owned in ${OWNED_SIMULATORS[@]+"${OWNED_SIMULATORS[@]}"}; do
    xcrun simctl shutdown "$owned" >/dev/null 2>&1 || true
    xcrun simctl delete "$owned" >/dev/null 2>&1 || true
  done
}
# Bash 3.2 can enter EXIT with status 0 after nounset. Only the successful
# three-batch/count verdict below is allowed to mark this runner complete.
RUNNER_COMPLETED=0
trap 'cleanup_rc=$?; trap - EXIT; set +e; if [ "$cleanup_rc" -eq 0 ] && [ "$RUNNER_COMPLETED" -ne 1 ]; then cleanup_rc=1; fi; cleanup; exit "$cleanup_rc"' EXIT
select_simulator_type() {
  xcrun simctl list runtimes --json > build/TestResults/runtimes.json
  xcrun simctl list devicetypes --json > build/TestResults/devicetypes.json
  python3 - <<'PY' > build/TestResults/simulator-selection.txt
import json
from pathlib import Path
runtimes = json.loads(Path('build/TestResults/runtimes.json').read_text())['runtimes']
runtimes = [r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']]
if not runtimes:
    raise SystemExit('error: no available iOS Simulator runtime')
runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
types = json.loads(Path('build/TestResults/devicetypes.json').read_text())['devicetypes']
ipads = [d for d in types if d['name'].startswith('iPad')]
if not ipads:
    raise SystemExit('error: no iPad Simulator device type')
device = next((d for d in ipads if 'iPad-Pro-11-inch-M4-' in d['identifier']), ipads[-1])
print(device['identifier'])
print(runtime['identifier'])
PY
  DEVICE_TYPE="$(sed -n '1p' build/TestResults/simulator-selection.txt)"
  RUNTIME="$(sed -n '2p' build/TestResults/simulator-selection.txt)"
}
if [ -z "$SIMULATOR_ID" ]; then
  select_simulator_type
  SIMULATOR_ID="$(xcrun simctl create "DSH-XCTest-${GITHUB_RUN_ID:-local}-$$" "$DEVICE_TYPE" "$RUNTIME")"
  OWNED_SIMULATORS+=("$SIMULATOR_ID")
fi
echo "XCTest destination: iPad simulator $SIMULATOR_ID"
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b

# Setup compiles and installs the app without launching it. Apply the simulator
# TCC revoke operation before routes run; UI tests also use a fresh device below
# because an unresolved permission prompt can survive the hosted test process.
# This action is not counted as a test result; all three test actions must run.
xcodebuild \
  -project DSH.xcodeproj -scheme DSH -configuration Release \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -destination-timeout 120 \
  -derivedDataPath "$PWD/build/DerivedData-XCTest" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  COMPILER_INDEX_STORE_ENABLE=NO build-for-testing 2>&1 | tee cilogs/03b-xctest-setup.log
xcrun simctl install "$SIMULATOR_ID" \
  "$PWD/build/DerivedData-XCTest/Build/Products/Release-iphonesimulator/DSH.app"
xcrun simctl privacy "$SIMULATOR_ID" revoke all com.xnuapp.dsh

collect_persistent_diagnostics() {
  # Capture only the app's existing redacted launch reports, never its rootfs,
  # preferences or credentials. UI application stdout is absent from the
  # XCTest runner log, so these reports explain guest exits on failed runs.
  local batch="$1" container diagnostics log_file
  container="$(xcrun simctl get_app_container "$SIMULATOR_ID" com.xnuapp.dsh data 2>/dev/null)" || return 0
  [ -n "$container" ] || return 0
  diagnostics="$container/Library/Application Support/Diagnostics"
  [ -d "$diagnostics" ] || return 0
  mkdir -p "cilogs/diagnostics-$batch"
  for log_file in "$diagnostics"/launch-*.log; do
    [ -f "$log_file" ] || continue
    cp "$log_file" "cilogs/diagnostics-$batch/"
  done
}

run_batch() {
  local batch="$1"
  shift
  local result_path="$PWD/build/TestResults/DSH-${batch}-$$.xcresult"
  local xcode_rc report_rc
  set +e
  xcodebuild \
    -project DSH.xcodeproj -scheme DSH -configuration Release \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -destination-timeout 120 \
    -derivedDataPath "$PWD/build/DerivedData-XCTest" \
    -resultBundlePath "$result_path" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 900 \
    -maximum-test-execution-time-allowance 1200 \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    COMPILER_INDEX_STORE_ENABLE=NO "$@" test 2>&1 | tee "cilogs/04-xctest-${batch}.log"
  xcode_rc=${PIPESTATUS[0]}
  collect_persistent_diagnostics "$batch" || echo "note: could not collect $batch launch reports" >&2
  python3 scripts/report-xctests.py --xcresult "$result_path" --label "$batch" \
    --json-output "build/TestResults/${batch}-counts.json" \
    --markdown-output "cilogs/xctest-${batch}-summary.md"
  report_rc=$?
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "cilogs/xctest-${batch}-summary.md" ]; then
    cat "cilogs/xctest-${batch}-summary.md" >> "$GITHUB_STEP_SUMMARY"
  fi
  set -e
  if [ "$xcode_rc" != 0 ] || [ "$report_rc" != 0 ]; then
    echo "error: $batch failed (xcodebuild=$xcode_rc, xcresult verification=$report_rc)" >&2
    return 1
  fi
}

# The TestAction sets DSH_TEST_HOST=1: app launch creates a blank test scene,
# without importing roots, starting Node, or observing fake harness instances.
# Exclusions partition the suite; the second invocation executes both classes.
rc_unit=0
run_batch unit -only-testing:DSHTests \
  -skip-testing:DSHTests/DSHGuestIntegrationTests \
  -skip-testing:DSHTests/DSHCapabilityReportTests || rc_unit=$?
rc_integration=0
TEST_RUNNER_DSH_GUEST_INTEGRATION=1 run_batch integration \
  -only-testing:DSHTests/DSHGuestIntegrationTests \
  -only-testing:DSHTests/DSHCapabilityReportTests || rc_integration=$?

# Hosted capability tests intentionally exercise first-request routes. Their
# pending SpringBoard prompts must not leak into the UI batch. A new disposable
# simulator isolates those requests without altering production permissions or
# erasing an externally supplied simulator (or any user's app data).
for owned in ${OWNED_SIMULATORS[@]+"${OWNED_SIMULATORS[@]}"}; do
  xcrun simctl shutdown "$owned" >/dev/null 2>&1 || true
done
if [ -z "${DEVICE_TYPE:-}" ]; then
  select_simulator_type
fi
SIMULATOR_ID="$(xcrun simctl create "DSH-UI-XCTest-${GITHUB_RUN_ID:-local}-$$" "$DEVICE_TYPE" "$RUNTIME")"
OWNED_SIMULATORS+=("$SIMULATOR_ID")
echo "UI XCTest destination: fresh iPad simulator $SIMULATOR_ID"
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" \
  "$PWD/build/DerivedData-XCTest/Build/Products/Release-iphonesimulator/DSH.app"
xcrun simctl privacy "$SIMULATOR_ID" revoke all com.xnuapp.dsh
rc_ui=0
if [ "${DSH_UI_WELCOME_EVENTS_ONLY:-0}" = 1 ]; then
  # Diagnostic only. Units/integration above remain real; this
  # single UI case observes the first Welcome without layout reads.
  run_batch ui -only-testing:DSHUITests/DSHLaunchUITests/testActivityScreenIsReachableAndReadable || rc_ui=$?
  echo "DIAGNOSTIC ONLY: UI case exit=$rc_ui; no full UI acceptance or IPA authorization"
  exit 1
fi
run_batch ui -only-testing:DSHUITests || rc_ui=$?

# Counts are disjoint because classes are partitioned above; filters are not
# represented as skipped test executions. Never hide the individual failures.
python3 - <<'PY' | tee cilogs/xctest-total-summary.md
import json
from pathlib import Path
rows = [json.loads(Path(f'build/TestResults/{part}-counts.json').read_text())
        for part in ('unit', 'integration', 'ui')]
print('### Simulator XCTest: combined\n')
print('| Executed | Passed | Failed | Skipped |')
print('|---:|---:|---:|---:|')
print('| ' + ' | '.join(str(sum(r[k] for r in rows))
                        for k in ('executed', 'passed', 'failed', 'skipped')) + ' |')
PY
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat cilogs/xctest-total-summary.md >> "$GITHUB_STEP_SUMMARY"
fi
test "$rc_unit" = 0 && test "$rc_integration" = 0 && test "$rc_ui" = 0 || exit 1
RUNNER_COMPLETED=1
