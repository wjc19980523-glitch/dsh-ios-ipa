#!/usr/bin/env python3
"""Portable reader controls only; these never claim to execute Native XCTest."""
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
SPEC = importlib.util.spec_from_file_location("required_export_tests", ROOT / "scripts/check-required-export-tests.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class RequiredExportTestsGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dsh-required-export-tests-")
        self.directory = Path(self.temporary.name)
        self.bundle = self.directory / "DSH-unit-123.xcresult"
        self.bundle.mkdir()
        self.database = self.bundle / "database.sqlite3"
        with contextlib.closing(sqlite3.connect(self.database)) as connection, connection:
            # Real xcresult column order varies; exercise reversed known order.
            for table, columns in gate.SCHEMA.items():
                fields = ", ".join(name + " " + kind for name, kind in reversed(list(columns.items())))
                connection.execute('CREATE TABLE "' + table + '" (' + fields + ')')
            for rowid, identity in enumerate(gate.required_identities(), 1):
                connection.execute("INSERT INTO TestCases(rowid,identifier,name,testSuite_fk) VALUES(?,?,?,1)",
                                   (rowid, identity, identity.split("/", 1)[1]))
                connection.execute("INSERT INTO TestCaseRuns(rowid,testCase_fk,testSuiteRun_fk,result,duration) VALUES(?,?,1,'Success',0.01)", (rowid, rowid))

    def tearDown(self):
        self.temporary.cleanup()

    def change(self, sql, parameters=()):
        with contextlib.closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(sql, parameters)

    def assert_rejected(self, message):
        with self.assertRaisesRegex(gate.GateError, message):
            gate.inspect_database(self.bundle)

    def test_known_schema_and_all_51_unconditional_successes_pass_read_only(self):
        before = gate.digest(self.database)
        report = gate.inspect_database(self.bundle)
        self.assertEqual(report["new_native_passed"], 46)
        self.assertEqual(report["original_confirmation_passed"], 5)
        self.assertEqual(len(report["required"]), 51)
        self.assertEqual(gate.digest(self.database), before)
        self.assertFalse(self.database.with_name("database.sqlite3-wal").exists())

    def test_fixed_source_selectors_have_exact_15_4_19_13_counts(self):
        sources = gate.verify_sources(ROOT)
        self.assertEqual([source["selectors"] for source in sources], [15, 4, 19, 13])
        self.assertEqual(len(gate.required_identities()), 51)
        self.assertEqual(len(gate.LEGACY_CONFIRMATION), 5)

    def test_missing_required_selector_is_rejected(self):
        self.change("DELETE FROM TestCaseRuns WHERE rowid=1")
        self.assert_rejected("absent or repeated")

    def test_duplicate_required_execution_is_rejected(self):
        self.change("INSERT INTO TestCaseRuns(testCase_fk,testSuiteRun_fk,result,duration) VALUES(1,1,'Success',0.01)")
        self.assert_rejected("absent or repeated")

    def test_failure_skip_expected_failure_and_unknown_outcomes_are_rejected(self):
        for result in ("Failure", "Skipped", "ExpectedFailure", "Passed", "Unknown"):
            with self.subTest(result=result):
                self.change("UPDATE TestCaseRuns SET result=? WHERE rowid=1", (result,))
                self.assert_rejected("unconditional Success")

    def test_expected_failure_table_rejects_even_a_success_result(self):
        self.change("INSERT INTO ExpectedFailures(testCaseRun_fk,failureReason) VALUES(1,'fixture expected failure')")
        self.assert_rejected("Expected failures are present")

    def test_success_with_a_skip_notice_is_rejected(self):
        self.change("UPDATE TestCaseRuns SET skipNotice_fk=1 WHERE rowid=1")
        self.assert_rejected("unconditional Success")

    def test_identifier_and_method_name_must_match(self):
        self.change("UPDATE TestCases SET name='testDifferentSelector' WHERE rowid=1")
        self.assert_rejected("unconditional Success")

    def test_unknown_extra_column_is_rejected(self):
        self.change("ALTER TABLE TestCaseRuns ADD COLUMN futureOutcome TEXT")
        self.assert_rejected("Unrecognized xcresult schema")

    def test_missing_expected_failure_schema_is_rejected(self):
        self.change("DROP TABLE ExpectedFailures")
        self.assert_rejected("Unrecognized xcresult table")

    def test_orphaned_test_run_is_rejected(self):
        self.change("UPDATE TestCaseRuns SET testCase_fk=99999 WHERE rowid=1")
        self.assert_rejected("orphaned test runs")

    def test_incomplete_database_writer_journal_is_rejected(self):
        self.database.with_name("database.sqlite3-wal").write_bytes(b"unfinished writer")
        self.assert_rejected("writer journal")

    def test_missing_and_ambiguous_unit_bundles_are_rejected(self):
        self.assertEqual(gate.select_bundle(self.directory), self.bundle)
        another = self.directory / "DSH-unit-456.xcresult"
        another.mkdir()
        with self.assertRaisesRegex(gate.GateError, "exactly one"):
            gate.select_bundle(self.directory)
        self.database.unlink()
        self.bundle.rmdir()
        another.rmdir()
        with self.assertRaisesRegex(gate.GateError, "exactly one"):
            gate.select_bundle(self.directory)

    def test_corrupt_database_and_invalid_duration_are_rejected(self):
        self.change("UPDATE TestCaseRuns SET duration=-1 WHERE rowid=1")
        self.assert_rejected("invalid execution duration")
        self.database.write_bytes(b"not a sqlite database")
        with self.assertRaises(sqlite3.DatabaseError):
            gate.inspect_database(self.bundle)

    def test_source_missing_or_duplicated_selector_is_rejected(self):
        source_root = self.directory / "source"
        folder = source_root / "tests/DSHTests"
        folder.mkdir(parents=True)
        for test_class, methods in gate.EXPECTED.items():
            (folder / (test_class + ".m")).write_text("\n".join("- (void)" + method + " {}" for method in methods), encoding="utf-8")
        self.assertEqual(len(gate.verify_sources(source_root)), 4)
        path = folder / "DSHBinaryBridgeTests.m"
        path.write_text(path.read_text(encoding="utf-8") + "\n- (void)testActualBinaryWithNulAndNonUTF8CrossesSocketWithoutJSON {}", encoding="utf-8")
        with self.assertRaisesRegex(gate.GateError, "selectors differ"):
            gate.verify_sources(source_root)

    def test_source_skip_directive_is_rejected(self):
        source_root = self.directory / "source"
        folder = source_root / "tests/DSHTests"
        folder.mkdir(parents=True)
        for test_class, methods in gate.EXPECTED.items():
            (folder / (test_class + ".m")).write_text("\n".join("- (void)" + method + " {}" for method in methods), encoding="utf-8")
        path = folder / "DSHBinaryBridgeTests.m"
        path.write_text(path.read_text(encoding="utf-8") + "\nXCTSkip(\"fixture\");", encoding="utf-8")
        with self.assertRaisesRegex(gate.GateError, "skip or expected-failure"):
            gate.verify_sources(source_root)

    def test_cli_records_success_and_never_overwrites_a_receipt(self):
        output = self.directory / "receipt.json"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gate.main(["--xcresult", str(self.bundle), "--json-output", str(output)])
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(output.read_text(encoding="utf-8"))["passed"])
        before = output.read_bytes()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gate.main(["--xcresult", str(self.bundle), "--json-output", str(output)])
        self.assertEqual(code, 1)
        self.assertEqual(output.read_bytes(), before)

    def test_cli_writes_a_failure_receipt_for_missing_required_execution(self):
        self.change("DELETE FROM TestCaseRuns WHERE rowid=1")
        output = self.directory / "failure.json"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gate.main(["--results-dir", str(self.directory), "--json-output", str(output)])
        receipt = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(code, 1)
        self.assertFalse(receipt["passed"])
        self.assertIn("absent or repeated", receipt["failure"])


if __name__ == "__main__":
    unittest.main()
