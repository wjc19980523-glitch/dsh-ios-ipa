#!/usr/bin/env python3
"""Require the eight real Native upgrade and three real WK input XCTests.

Fail closed against the completed Xcode result SQLite schema actually observed
in this project, and cross-check every execution against its original batch log.
Portable parser controls are not execution of the Native or WKWebView tests.
"""
import argparse
from collections import Counter
from contextlib import closing
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    "unit": {"DSHSessionLifecycleInstallerTests": (
        "testActualOnboardingFreshAndBuild29UpgradeAreExactAndIdempotent",
        "testOnboardingUpgradeResourceWhitelistAndHashFailEvenWhenAlreadyCurrent",
        "testOnboardingUpgradeRequiresOnlyPinnedBaseAndKnownBuild29Previous",
        "testOnboardingUpgradeCannotCrossTargetsOrInstallAdditionalGuestFiles",
        "testOnboardingUpgradeRejectsUnknownAndLinkedSourcesBeforeWrites",
        "testOnboardingUpgradeDoesNotOverwriteTargetChangedAfterPreflight",
        "testOnboardingUpgradeIOFailuresPreserveBuild29AndAllowExplicitRetry",
        "testOnboardingUpgradeValidatesCanonicalPatchEvenOnIdempotentPath",
    )},
    "ui": {"DSHWelcomeTouchUITests": (
        "testWelcomeTouchCancelsCompatibilityClickAndWaitsForPersistence",
        "testWelcomeTouchQuickAndSlowTapsDoNotProduceCompatibilityClicks",
        "testWelcomeTouchFailureAndRejectionRequireAnotherExplicitGesture",
    )},
}
SCHEMA = {
    "TestCases": {"identifier": "TEXT", "orderInTestSuite": "INTEGER", "name": "TEXT",
                  "summary": "TEXT", "identifierURL": "TEXT", "testSuite_fk": "INTEGER"},
    "TestCaseRuns": {"testSuiteRun_fk": "INTEGER", "orderInTestSuiteRun": "INTEGER",
                     "testCase_fk": "INTEGER", "duration": "REAL", "result": "TEXT",
                     "skipNotice_fk": "INTEGER", "repetitionPolicy_fk": "INTEGER",
                     "dynamicTestParameters_fk": "INTEGER"},
    "ExpectedFailures": {"orderInOwner": "INTEGER", "uuid": "TEXT", "issue_fk": "INTEGER",
                         "testSuiteRun_fk": "INTEGER", "failureReason": "TEXT",
                         "isTopLevelFailure": "INTEGER", "testCaseRun_fk": "INTEGER"},
}
# XCTest and framework writers share stdout. Real official logs can place an
# entire completion fragment after or before another writer on the same line.
# Match the complete literal fragment, retaining exact class/method/outcome;
# never stitch truncated fragments or normalize selector spellings.
CASE_PATTERN = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)\.")


class GateError(RuntimeError):
    pass


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def required_identities(batch=None):
    groups = EXPECTED if batch is None else {batch: EXPECTED[batch]}
    identities = [test_class + "/" + method for classes in groups.values()
                  for test_class, methods in classes.items() for method in methods]
    wanted = 11 if batch is None else {"unit": 8, "ui": 3}[batch]
    if len(identities) != wanted or len(set(identities)) != wanted:
        raise GateError("Fixed Welcome selector list is invalid")
    return identities


def verify_sources(root):
    required_identities()
    sources = []
    for batch, classes in EXPECTED.items():
        for test_class, methods in classes.items():
            path = Path(root) / ("tests/DSHTests" if batch == "unit" else "tests/DSHUITests") / (test_class + ".m")
            if not path.is_file() or path.is_symlink():
                raise GateError("Required test source is absent or unsafe: " + test_class)
            content = path.read_text(encoding="utf-8")
            found = re.findall(r"^- \(void\)(test\w+)\s*(?:\{|$)", content, re.MULTILINE)
            counts = Counter(found)
            if any(counts[name] != 1 for name in methods) or any(n != 1 for n in counts.values()):
                raise GateError("Required source selector is absent or duplicated: " + test_class)
            if batch == "ui" and Counter(found) != Counter(methods):
                raise GateError("WK input source differs from the fixed three methods")
            if re.search(r"\b(?:XCTSkip|XCTSkipIf|XCTSkipUnless|XCTExpectFailure)\s*\(", content):
                raise GateError("Required sources contain a skip or expected-failure directive: " + test_class)
            sources.append({"path": str(path.relative_to(root)), "sha256": digest(path),
                            "required_selectors": len(methods), "total_source_selectors": len(found)})
    return sources


def select_bundle(results_dir, batch):
    bundles = list(Path(results_dir).glob("DSH-" + batch + "-*.xcresult"))
    if len(bundles) != 1:
        raise GateError("Expected exactly one completed " + batch + " xcresult bundle")
    return bundles[0]


def inspect_database(bundle):
    bundle = Path(bundle)
    database = bundle / "database.sqlite3"
    if (not bundle.is_dir() or bundle.is_symlink() or not database.is_file()
            or database.is_symlink() or not 0 < database.stat().st_size <= 512 * 1024 * 1024):
        raise GateError("Missing, unsafe or oversized xcresult database")
    if any(database.with_name(database.name + suffix).exists() for suffix in ("-wal", "-journal")):
        raise GateError("xcresult still has a writer journal")
    before = digest(database)
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        connection.execute("PRAGMA query_only=ON")
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise GateError("xcresult integrity check failed")
        schema_sql = {}
        for table, expected in SCHEMA.items():
            rows = connection.execute("SELECT type,sql FROM sqlite_master WHERE name=?", (table,)).fetchall()
            if len(rows) != 1 or rows[0][0] != "table":
                raise GateError("Unrecognized xcresult table: " + table)
            columns = {column[1]: column[2].upper() for column in connection.execute('PRAGMA table_info("' + table + '")')}
            if columns != expected:
                raise GateError("Unrecognized xcresult schema: " + table)
            schema_sql[table] = rows[0][1]
        if connection.execute("SELECT count(*) FROM ExpectedFailures").fetchone()[0] != 0:
            raise GateError("Expected failures are present in the result bundle")
        declared = [row[0] for row in connection.execute("SELECT identifier FROM TestCases")]
        rows = connection.execute("SELECT tc.identifier,tc.name,tr.result,tr.skipNotice_fk,tr.duration "
                                  "FROM TestCaseRuns tr JOIN TestCases tc ON tc.rowid=tr.testCase_fk").fetchall()
        if len(rows) != connection.execute("SELECT count(*) FROM TestCaseRuns").fetchone()[0]:
            raise GateError("xcresult contains orphaned test runs")
    if digest(database) != before:
        raise GateError("xcresult changed during inspection")
    runs = []
    for identity, method, result, skip_notice, duration in rows:
        if not isinstance(identity, str) or not isinstance(method, str) or result not in ("Success", "Failure", "Skipped"):
            raise GateError("Unrecognized XCTest identity or outcome")
        if not isinstance(duration, (float, int)) or not math.isfinite(duration) or duration < 0:
            raise GateError("Invalid XCTest execution duration")
        runs.append({"identity": identity, "method": method, "result": result,
                     "skip_notice": skip_notice, "duration_seconds": duration})
    return {"bundle": str(bundle), "database_sha256": before, "schema_sql": schema_sql,
            "declared": declared, "runs": runs, "expected_failures": 0}


def inspect_log(path, runs):
    path = Path(path)
    if not path.is_file() or path.is_symlink() or not 0 < path.stat().st_size <= 128 * 1024 * 1024:
        raise GateError("Original batch log is missing, unsafe or oversized")
    before = digest(path)
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(encoding="utf-8"))
    if digest(path) != before:
        raise GateError("Batch log changed during inspection")
    actual = [(m[1] + "/" + m[2], m[3]) for m in CASE_PATTERN.finditer(text)]
    expected = [(row["identity"], {"Success": "passed", "Failure": "failed", "Skipped": "skipped"}[row["result"]]) for row in runs]
    if Counter(actual) != Counter(expected):
        raise GateError("Original batch log execution identities/results differ from SQLite")
    if text.count("** TEST SUCCEEDED **") != 1 or "** TEST FAILED **" in text:
        raise GateError("Original batch log lacks a unique successful XCTest completion")
    return {"path": str(path), "sha256": before, "executions": len(actual), "identity_results_match": True}


def inspect_results(results_dir, logs_dir):
    batches = {}
    for batch in EXPECTED:
        value = inspect_database(select_bundle(results_dir, batch))
        value["batch_log"] = inspect_log(Path(logs_dir) / ("04-xctest-" + batch + ".log"), value["runs"])
        batches[batch] = value
    all_runs = [(batch, row) for batch, value in batches.items() for row in value["runs"]]
    all_declared = Counter(identity for value in batches.values() for identity in value["declared"])
    required = []
    for batch in EXPECTED:
        for identity in required_identities(batch):
            own = [(owner, row) for owner, row in all_runs if row["identity"] == identity]
            if len(own) != 1 or all_declared[identity] != 1:
                raise GateError("Required XCTest is missing or duplicated: " + identity)
            owner, row = own[0]
            if (owner != batch or row["method"] != identity.split("/", 1)[1]
                    or row["result"] != "Success" or row["skip_notice"] is not None):
                raise GateError("Required XCTest did not execute in its batch as unconditional Success: " + identity)
            required.append(dict(batch=batch, **row))
    return {"required": required, "native_upgrade_passed": 8, "wk_input_passed": 3,
            "required_failed": 0, "required_skipped": 0, "expected_failures": 0,
            "batches": {batch: {k: value[k] for k in ("bundle", "database_sha256", "schema_sql", "batch_log")}
                        for batch, value in batches.items()}}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", required=True, type=Path)
    parser.add_argument("--logs-dir", required=True, type=Path)
    parser.add_argument("--json-output", required=True, type=Path)
    args = parser.parse_args(argv)
    receipt = {"schema": 1, "gate": "required-welcome-upgrade-and-wk-input-tests", "passed": False,
               "github_sha": os.environ.get("GITHUB_SHA"), "github_run_id": os.environ.get("GITHUB_RUN_ID"),
               "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
               "limits": ["Real WK input tests use controlled persistence states; they do not certify Host/profile writes.",
                          "Original normal observer-OFF guest startup and the existing 51-test gate remain mandatory."]}
    try:
        receipt["source_files"] = verify_sources(ROOT)
        receipt.update(inspect_results(args.results_dir, args.logs_dir))
        receipt["passed"] = True
    except (GateError, OSError, sqlite3.Error, UnicodeError, ValueError) as error:
        receipt["failure"] = str(error)
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with args.json_output.open("x", encoding="utf-8") as output:
            json.dump(receipt, output, ensure_ascii=False, indent=2, allow_nan=False)
            output.write("\n")
    except (OSError, ValueError) as error:
        print("error: cannot write a fresh Welcome gate receipt: " + str(error), file=sys.stderr)
        return 1
    if not receipt["passed"]:
        print("error: required Welcome XCTest gate failed: " + receipt["failure"], file=sys.stderr)
        return 1
    print("ok: 8 Native upgrade and 3 real WK input XCTests each executed once as Success; original batch logs agree; 0 failed/skipped/expected-failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
