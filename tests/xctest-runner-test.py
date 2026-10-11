#!/usr/bin/env python3
"""macOS/Linux regressions for XCTest count validation and pipeline exit codes."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("report_xctests", ROOT / "scripts/report-xctests.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
selection_spec = importlib.util.spec_from_file_location("select_xcode", ROOT / "scripts/select-xcode.py")
selection = importlib.util.module_from_spec(selection_spec)
selection_spec.loader.exec_module(selection)


class XcodeSelectionTests(unittest.TestCase):
    def test_latest_xcode_uses_numeric_version_order(self):
        with tempfile.TemporaryDirectory(prefix="dsh-xcodes-") as directory:
            for name in ("Xcode_26.0.1.app", "Xcode_26.6.app", "Xcode_26.10.app"):
                (Path(directory) / name / "Contents/Developer").mkdir(parents=True)
            self.assertEqual(selection.select_xcode(directory).name, "Xcode_26.10.app")
            (Path(directory) / "Xcode_27.0.app/Contents/Developer").mkdir(parents=True)
            self.assertEqual(selection.select_xcode(directory).name, "Xcode_27.0.app")

    def test_requested_installed_version_is_honored(self):
        with tempfile.TemporaryDirectory(prefix="dsh-xcodes-") as directory:
            requested = Path(directory) / "Explicit Xcode.app"
            (requested / "Contents/Developer").mkdir(parents=True)
            self.assertEqual(selection.select_xcode(directory, str(requested)), requested)

    def test_invalid_request_or_empty_inventory_fails(self):
        with tempfile.TemporaryDirectory(prefix="dsh-xcodes-") as directory:
            with self.assertRaises(ValueError):
                selection.select_xcode(directory)
            with self.assertRaises(ValueError):
                selection.select_xcode(directory, str(Path(directory) / "Missing.app"))


class XCTestSummaryTests(unittest.TestCase):
    def test_counts_are_actual_executions_excluding_skips(self):
        counts = report.summarize({"totalTestCount": 5, "passedTests": 4,
                                   "failedTests": 0, "skippedTests": 1, "result": "Passed"})
        self.assertEqual(counts["executed"], 4)
        self.assertEqual(counts["skipped"], 1)

    def test_missing_or_inconsistent_counts_are_rejected(self):
        for data in ({}, {"totalTestCount": 1, "passedTests": 2,
                         "failedTests": 0, "skippedTests": 0},
                     {"totalTestCount": 1, "passedTests": 0,
                      "failedTests": 0, "skippedTests": 0}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                report.summarize(data)

    def test_report_cli_rejects_empty_skipped_failed_and_build_only_runs(self):
        base = {"totalTestCount": 5, "passedTests": 4, "failedTests": 0,
                "skippedTests": 1, "result": "Passed"}
        fixtures = [
            ("passed", base, 0),
            ("zero", {**base, "totalTestCount": 0, "passedTests": 0, "skippedTests": 0}, 1),
            ("all-skipped", {**base, "passedTests": 0, "skippedTests": 5}, 1),
            ("failed", {**base, "passedTests": 3, "failedTests": 1, "result": "Failed"}, 1),
            ("build-only", {}, 1),
            ("build-failed", {**base, "result": "Failed"}, 1),
        ]
        with tempfile.TemporaryDirectory(prefix="dsh-xcresult-") as directory:
            fixture = Path(directory) / "summary.json"
            for label, data, expected in fixtures:
                with self.subTest(label=label):
                    fixture.write_text(json.dumps(data), encoding="utf-8")
                    result = subprocess.run([
                        shutil.which("python3"), str(ROOT / "scripts/report-xctests.py"),
                        "--summary-json", str(fixture), "--label", label,
                    ], text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


FAKE_XCRUN = '''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1] == 'simctl':
    if sys.argv[2:4] == ['list', 'runtimes']:
        print(json.dumps({'runtimes': [{'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-6', 'version': '26.6'}]}))
    if sys.argv[2:4] == ['list', 'devicetypes']:
        print(json.dumps({'devicetypes': [{'name': 'iPad Pro', 'identifier': 'fixture-ipad-type'}]}))
    if sys.argv[2] == 'create':
        with open('invocations.txt', 'a') as log:
            log.write('create-ui\\n')
        print('fresh-ui-simulator')
    if sys.argv[2] == 'get_app_container':
        print(os.path.abspath('fixture-app'))
    if sys.argv[2] == 'delete':
        assert sys.argv[3] == 'fresh-ui-simulator', sys.argv
    if sys.argv[2] in ('install', 'privacy'):
        with open('invocations.txt', 'a') as log:
            log.write(sys.argv[2] + '\\n')
    if sys.argv[2] == 'privacy':
        assert sys.argv[4:] == ['revoke', 'all', 'com.xnuapp.dsh'], sys.argv
        if os.environ['FAKE_CASE'] == 'privacy-fail':
            sys.exit(1)
        if os.environ['FAKE_CASE'] == 'ui-privacy-fail' and sys.argv[3] == 'fresh-ui-simulator':
            sys.exit(1)
    sys.exit(0)
assert sys.argv[1:4] == ['xcresulttool', 'get', 'test-results']
path = sys.argv[sys.argv.index('--path') + 1]
unit = 'unit-' in path
case = os.environ['FAKE_CASE']
summary = {'totalTestCount': 3, 'passedTests': 3, 'failedTests': 0,
           'skippedTests': 0, 'result': 'Passed'}
if unit and case == 'zero-tests':
    summary.update(totalTestCount=0, passedTests=0)
if unit and case == 'failed-tests':
    summary.update(passedTests=2, failedTests=1, result='Failed')
print(json.dumps(summary))
'''

FAKE_XCODEBUILD = '''#!/usr/bin/env python3
import os, pathlib, sys
assert 'archive' not in sys.argv, sys.argv
if sys.argv[-1] == 'build-for-testing':
    with pathlib.Path('invocations.txt').open('a') as log:
        log.write('setup\\n')
    sys.exit(65 if os.environ['FAKE_CASE'] == 'setup-fail' else 0)
assert sys.argv[-1] == 'test', sys.argv
path = sys.argv[sys.argv.index('-resultBundlePath') + 1]
unit = 'unit-' in path
ui = 'ui-' in path
destination = sys.argv[sys.argv.index('-destination') + 1]
assert destination.endswith('fresh-ui-simulator' if ui else 'fixture-simulator'), destination
flag = os.environ.get('TEST_RUNNER_DSH_GUEST_INTEGRATION', '')
assert flag == ('1' if not unit and not ui else ''), (unit, ui, flag)
with pathlib.Path('invocations.txt').open('a') as log:
    log.write(('unit' if unit else 'ui' if ui else 'integration') + '\\n')
print('stub xcodebuild: test action requested')
sys.exit(65 if ((unit and os.environ['FAKE_CASE'] == 'xcode-fail') or
               (ui and os.environ['FAKE_CASE'] == 'ui-fail')) else 0)
'''


class XCTestRunnerTests(unittest.TestCase):
    def run_case(self, case, expected):
        with tempfile.TemporaryDirectory(prefix="dsh-xctest-runner-") as directory:
            task = Path(directory)
            (task / "scripts").mkdir()
            (task / "bin").mkdir()
            for name in ("run-xctests.sh", "report-xctests.py"):
                shutil.copy2(ROOT / "scripts" / name, task / "scripts" / name)
            for name, content in (("xcrun", FAKE_XCRUN), ("xcodebuild", FAKE_XCODEBUILD)):
                command = task / "bin" / name
                command.write_text(content, encoding="utf-8")
                command.chmod(0o755)
            environment = {**os.environ, "PATH": str(task / "bin") + os.pathsep + os.environ["PATH"],
                           "DSH_TEST_SIMULATOR_ID": "fixture-simulator", "FAKE_CASE": case,
                           "GITHUB_STEP_SUMMARY": str(task / "summary.md")}
            environment.pop("TEST_RUNNER_DSH_GUEST_INTEGRATION", None)
            diagnostics = task / "fixture-app/Library/Application Support/Diagnostics"
            diagnostics.mkdir(parents=True)
            (diagnostics / "launch-fixture.log").write_text("guest exit: pid=7 status=0\n", encoding="utf-8")
            (diagnostics / "unrelated-config.json").write_text("must not be collected", encoding="utf-8")
            result = subprocess.run(["bash", "scripts/run-xctests.sh"], cwd=task,
                                    env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            expected_calls = ["setup"] if case == "setup-fail" else ["setup", "install", "privacy"]
            if case not in ("setup-fail", "privacy-fail"):
                expected_calls += ["unit", "integration", "create-ui", "install", "privacy"]
                if case != "ui-privacy-fail":
                    expected_calls += ["ui"]
                self.assertTrue((task / "build/TestResults/integration-counts.json").exists())
                self.assertEqual((task / "build/TestResults/ui-counts.json").exists(), case != "ui-privacy-fail")
            self.assertEqual((task / "invocations.txt").read_text().splitlines(), expected_calls)
            if case not in ("setup-fail", "privacy-fail"):
                for batch in ("unit", "integration") + (() if case == "ui-privacy-fail" else ("ui",)):
                    captured = task / f"cilogs/diagnostics-{batch}"
                    self.assertEqual([p.name for p in captured.iterdir()], ["launch-fixture.log"])
                    self.assertEqual((captured / "launch-fixture.log").read_text(), "guest exit: pid=7 status=0\n")

    def test_success_runs_three_disjoint_batches(self):
        self.run_case("pass", 0)

    def test_xcodebuild_failure_survives_tee_and_second_batch(self):
        self.run_case("xcode-fail", 1)

    def test_ui_failure_fails_the_entire_run(self):
        self.run_case("ui-fail", 1)

    def test_zero_executed_fails_even_when_xcodebuild_passes(self):
        self.run_case("zero-tests", 1)

    def test_failed_xcresult_fails_even_when_xcodebuild_passes(self):
        self.run_case("failed-tests", 1)

    def test_setup_failure_never_counts_as_test_success(self):
        self.run_case("setup-fail", 65)

    def test_privacy_setup_failure_stops_before_tests(self):
        self.run_case("privacy-fail", 1)

    def test_fresh_ui_permission_setup_failure_cannot_pass(self):
        self.run_case("ui-privacy-fail", 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
