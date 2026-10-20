#!/usr/bin/env python3
"""Portable positive/negative reader controls, never a claim of Native execution."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("required_welcome_tests", ROOT / "scripts/check-required-welcome-tests.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class RequiredWelcomeGateControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dsh-welcome-reader-control-")
        self.folder = Path(self.temporary.name)
        self.results = self.folder / "results"
        self.logs = self.folder / "logs"
        self.results.mkdir()
        self.logs.mkdir()
        self.databases = {}
        for batch in gate.EXPECTED:
            bundle = self.results / ("DSH-" + batch + "-123.xcresult")
            bundle.mkdir()
            database = bundle / "database.sqlite3"
            self.databases[batch] = database
            with contextlib.closing(sqlite3.connect(database)) as connection, connection:
                for table, columns in gate.SCHEMA.items():
                    # Xcode changes column order between real bundles.
                    fields = ", ".join(name + " " + kind for name, kind in reversed(list(columns.items())))
                    connection.execute('CREATE TABLE "' + table + '" (' + fields + ')')
                for rowid, identity in enumerate(gate.required_identities(batch) + ["OtherTests/testOriginal"], 1):
                    connection.execute("INSERT INTO TestCases(rowid,identifier,name,testSuite_fk) VALUES(?,?,?,1)",
                                       (rowid, identity, identity.split("/", 1)[1]))
                    connection.execute("INSERT INTO TestCaseRuns(rowid,testCase_fk,testSuiteRun_fk,result,duration) VALUES(?,?,1,'Success',0.01)", (rowid, rowid))
            self.log_from_database(batch)

    def tearDown(self):
        self.temporary.cleanup()

    def change(self, batch, sql, values=(), refresh_log=True):
        with contextlib.closing(sqlite3.connect(self.databases[batch])) as connection, connection:
            connection.execute(sql, values)
        if refresh_log:
            self.log_from_database(batch)

    def log_from_database(self, batch):
        with contextlib.closing(sqlite3.connect(self.databases[batch])) as connection:
            rows = connection.execute("SELECT tc.identifier,tr.result FROM TestCaseRuns tr JOIN TestCases tc ON tc.rowid=tr.testCase_fk ORDER BY tr.rowid").fetchall()
        lines = []
        for identity, result in rows:
            test_class, method = identity.split("/", 1)
            outcome = {"Success": "passed", "Failure": "failed", "Skipped": "skipped"}.get(result, "unknown")
            lines.append("Test Case '-[" + test_class + " " + method + "]' " + outcome + " (0.010 seconds).")
        (self.logs / ("04-xctest-" + batch + ".log")).write_text("\n".join(lines) + "\n** TEST SUCCEEDED **\n", encoding="utf-8")

    def inspect(self):
        return gate.inspect_results(self.results, self.logs)

    def assert_rejected(self, message):
        with self.assertRaisesRegex(gate.GateError, message):
            self.inspect()

    def source_fixture(self):
        root = self.folder / "source"
        for batch, classes in gate.EXPECTED.items():
            folder = root / ("tests/DSHTests" if batch == "unit" else "tests/DSHUITests")
            folder.mkdir(parents=True, exist_ok=True)
            for test_class, methods in classes.items():
                (folder / (test_class + ".m")).write_text("\n".join("- (void)" + method + " {}" for method in methods), encoding="utf-8")
        return root

    def test_exact_8_native_and_3_wk_successes_crosscheck_logs_without_writing_databases(self):
        hashes = {batch: gate.digest(path) for batch, path in self.databases.items()}
        receipt = self.inspect()
        self.assertEqual(len(receipt["required"]), 11)
        self.assertEqual(receipt["native_upgrade_passed"], 8)
        self.assertEqual(receipt["wk_input_passed"], 3)
        self.assertEqual(hashes, {batch: gate.digest(path) for batch, path in self.databases.items()})
        self.assertEqual(receipt["batches"]["unit"]["batch_log"]["executions"], 9)

    def test_missing_native_and_wk_execution_rejected(self):
        for batch in ("unit", "ui"):
            with self.subTest(batch=batch):
                self.change(batch, "DELETE FROM TestCaseRuns WHERE rowid=1")
                self.assert_rejected("missing or duplicated")
                self.change(batch, "INSERT INTO TestCaseRuns(rowid,testCase_fk,testSuiteRun_fk,result,duration) VALUES(1,1,1,'Success',0.01)")

    def test_duplicate_execution_rejected_even_when_both_logs_agree(self):
        self.change("ui", "INSERT INTO TestCaseRuns(testCase_fk,testSuiteRun_fk,result,duration) VALUES(1,1,'Success',0.01)")
        self.assert_rejected("missing or duplicated")

    def test_duplicate_declared_selector_without_a_run_is_rejected(self):
        self.change("unit", "INSERT INTO TestCases(identifier,name) SELECT identifier,name FROM TestCases WHERE rowid=1")
        self.assert_rejected("missing or duplicated")

    def test_required_execution_in_wrong_batch_is_rejected(self):
        identity = gate.required_identities("ui")[0]
        self.change("ui", "DELETE FROM TestCaseRuns WHERE rowid=1")
        self.change("ui", "DELETE FROM TestCases WHERE rowid=1")
        self.change("unit", "INSERT INTO TestCases(rowid,identifier,name) VALUES(99,?,?)", (identity, identity.split("/", 1)[1]))
        self.change("unit", "INSERT INTO TestCaseRuns(testCase_fk,testSuiteRun_fk,result,duration) VALUES(99,1,'Success',0.01)")
        self.assert_rejected("in its batch")

    def test_failure_and_skip_are_not_unconditional_success(self):
        for batch in ("unit", "ui"):
            for outcome in ("Failure", "Skipped"):
                with self.subTest(batch=batch, outcome=outcome):
                    self.change(batch, "UPDATE TestCaseRuns SET result=? WHERE rowid=1", (outcome,))
                    self.assert_rejected("unconditional Success")
                    self.change(batch, "UPDATE TestCaseRuns SET result='Success' WHERE rowid=1")

    def test_passed_expected_failure_and_unknown_outcomes_rejected(self):
        for outcome in ("Passed", "ExpectedFailure", "Unknown"):
            with self.subTest(outcome=outcome):
                self.change("unit", "UPDATE TestCaseRuns SET result=? WHERE rowid=1", (outcome,))
                self.assert_rejected("Unrecognized XCTest")

    def test_skip_notice_with_success_rejected(self):
        self.change("ui", "UPDATE TestCaseRuns SET skipNotice_fk=1 WHERE rowid=1")
        self.assert_rejected("unconditional Success")

    def test_expected_failure_rows_rejected_in_either_bundle(self):
        for batch in ("unit", "ui"):
            with self.subTest(batch=batch):
                self.change(batch, "INSERT INTO ExpectedFailures(testCaseRun_fk,failureReason) VALUES(1,'control')")
                self.assert_rejected("Expected failures are present")
                self.change(batch, "DELETE FROM ExpectedFailures")

    def test_wrong_method_name_rejected(self):
        self.change("unit", "UPDATE TestCases SET name='testWrong' WHERE rowid=1")
        self.assert_rejected("unconditional Success")

    def test_unknown_schema_and_missing_expected_failures_table_fail_closed(self):
        self.change("unit", "ALTER TABLE TestCaseRuns ADD COLUMN futureOutcome TEXT")
        self.assert_rejected("Unrecognized xcresult schema")
        self.change("unit", "ALTER TABLE TestCaseRuns DROP COLUMN futureOutcome")
        self.change("ui", "DROP TABLE ExpectedFailures")
        self.assert_rejected("Unrecognized xcresult table")

    def test_view_cannot_impersonate_known_schema(self):
        self.change("unit", "ALTER TABLE ExpectedFailures RENAME TO HiddenFailures")
        self.change("unit", "CREATE VIEW ExpectedFailures AS SELECT * FROM HiddenFailures")
        self.assert_rejected("Unrecognized xcresult table")

    def test_orphaned_run_rejected(self):
        self.change("ui", "UPDATE TestCaseRuns SET testCase_fk=9999 WHERE rowid=1", refresh_log=False)
        self.assert_rejected("orphaned test runs")

    def test_writer_journal_and_corrupt_database_rejected(self):
        journal = self.databases["unit"].with_name("database.sqlite3-wal")
        journal.write_bytes(b"unfinished")
        self.assert_rejected("writer journal")
        journal.unlink()
        self.databases["ui"].write_bytes(b"not a database")
        with self.assertRaises(sqlite3.DatabaseError):
            self.inspect()

    def test_null_and_negative_duration_rejected(self):
        for duration in (None, -1):
            with self.subTest(duration=duration):
                self.change("unit", "UPDATE TestCaseRuns SET duration=? WHERE rowid=1", (duration,))
                self.assert_rejected("Invalid XCTest execution duration")

    def test_missing_ambiguous_and_unsafe_bundle_rejected(self):
        other = self.results / "DSH-unit-999.xcresult"
        other.mkdir()
        self.assert_rejected("exactly one")
        other.rmdir()
        self.databases["ui"].unlink()
        self.assert_rejected("Missing, unsafe")

    def test_log_identity_outcome_and_duplicate_disagreement_rejected(self):
        path = self.logs / "04-xctest-ui.log"
        original = path.read_text()
        for changed in (original.replace(" passed ", " failed ", 1), original + original.splitlines()[0] + "\n", original.replace("testWelcomeTouch", "testWrong", 1)):
            path.write_text(changed)
            self.assert_rejected("identities/results differ")

    def test_real_framework_prefix_and_suffix_interleaving_preserve_complete_fragments(self):
        path = self.logs / "04-xctest-unit.log"
        original = path.read_text()
        lines = original.splitlines()
        # Observed official fe log: "...finished with errorTest Case '-[...]' passed..."
        lines[0] = "2026-10-20 09:14:50.678750+0000 DSH[17036:55766] [Default] Task <opaque> finished with error" + lines[0]
        lines[1] += "2026-10-20 09:14:50.679000+0000 framework next asynchronous record"
        path.write_text("\n".join(lines) + "\n")
        self.assertEqual(len(self.inspect()["required"]), 11)

    def test_interleaving_does_not_allow_split_fragment_wrong_identity_or_duplicate(self):
        path = self.logs / "04-xctest-ui.log"
        original = path.read_text()
        first = original.splitlines()[0]
        for changed in (original.replace(" passed ", " pas\nsed ", 1),
                        original.replace("testWelcomeTouch", "testWelcomeTouchWrong", 1),
                        "framework prefix" + first + "framework suffix\n" + original):
            with self.subTest(changed=changed[:50]):
                path.write_text(changed)
                self.assert_rejected("identities/results differ")

    def test_missing_truncated_or_failed_completion_log_rejected(self):
        path = self.logs / "04-xctest-unit.log"
        original = path.read_text()
        for changed in (original.replace("** TEST SUCCEEDED **", ""), original + "** TEST FAILED **\n", original + "** TEST SUCCEEDED **\n"):
            path.write_text(changed)
            self.assert_rejected("unique successful")
        path.unlink()
        self.assert_rejected("batch log is missing")

    def test_unrelated_historical_skip_is_allowed_with_matching_original_log(self):
        self.change("unit", "UPDATE TestCaseRuns SET result='Skipped',skipNotice_fk=1 WHERE rowid=9")
        self.assertEqual(len(self.inspect()["required"]), 11)

    def test_source_exact_lists_and_duplicate_skip_controls(self):
        root = self.source_fixture()
        self.assertEqual([s["required_selectors"] for s in gate.verify_sources(root)], [8, 3])
        path = root / "tests/DSHUITests/DSHWelcomeTouchUITests.m"
        original = path.read_text()
        for changed in (original + "\n- (void)testWelcomeTouchQuickAndSlowTapsDoNotProduceCompatibilityClicks {}", original + "\nXCTSkip(\"control\");"):
            path.write_text(changed)
            with self.assertRaises(gate.GateError):
                gate.verify_sources(root)

    def test_cli_fresh_receipt_and_failure_receipt_never_overwrite(self):
        source = self.source_fixture()
        saved_root = gate.ROOT
        gate.ROOT = source
        receipt = self.folder / "receipt.json"
        arguments = ["--results-dir", str(self.results), "--logs-dir", str(self.logs), "--json-output", str(receipt)]
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main(arguments), 0)
                before = receipt.read_bytes()
                self.assertEqual(gate.main(arguments), 1)
                self.assertEqual(receipt.read_bytes(), before)
                self.change("ui", "DELETE FROM TestCaseRuns WHERE rowid=1")
                receipt.unlink()
                self.assertEqual(gate.main(arguments), 1)
                self.assertFalse(json.loads(receipt.read_text())["passed"])
        finally:
            gate.ROOT = saved_root


if __name__ == "__main__":
    unittest.main()
