#!/usr/bin/env python3
"""Fail closed unless Gate A's 46 new and five existing Native XCTests passed.

Reads the completed official xcresult SQLite database in read-only mode. This
schema was verified against an original Xcode macOS 26 result bundle. Portable
tests of this reader do not stand in for execution of the Native XCTests.
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
    "DSHWorkspaceExportStoreTests": (
        "testExportLargerThanEightMiBIsExactAndSavedOnlyAfterPickerEvidence",
        "testNoDataAcceptedBeforeConfirmationAndDenialIsTerminal",
        "testExactDuplicateStartIsIdempotentAndChangedMetadataRefused",
        "testOnlyOneActiveExportAndSessionIdentifiersAreRandom",
        "testLostAcknowledgementDuplicateDoesNotWriteOrHashTwice",
        "testBadChunkHashAndOutOfOrderBytesDoNotAdvanceOffset",
        "testOversizedChunkAndDeclaredFileOverflowAreRefused",
        "testIncompleteFileCannotBeCommittedOrPresented",
        "testWholeFileHashMismatchCleansAllStaging",
        "testCancelAndLatePickerSuccessNeverBecomeSaved",
        "testExpiryDuringSavingWaitsForUIKitAndRejectsLateSuccess",
        "testIdleAndAbsoluteExpiryCannotBeKeptAliveByPolling",
        "testBackgroundCancelsConfirmationAndSavingButNotAnUnrelatedTransfer",
        "testRestartRemovesIncompleteNativeFilesAndDoesNotPretendToResumeSaved",
        "testTraversalSensitivePathsNamesAndInvalidSizeAreRejectedBeforeDiskWrites",
    ),
    "DSHBinaryBridgeTests": (
        "testActualBinaryWithNulAndNonUTF8CrossesSocketWithoutJSON",
        "testBinaryRouteRetainsAuthenticationAndCapabilityGate",
        "testBinaryRouteRejectsWrongContentTypeAndOversizedBody",
        "testDisconnectedUploaderDoesNotTerminateTheHostWhenReplying",
    ),
    "DSHWorkspaceExportCapabilityTests": (
        "testWorkspaceExportHasItsOwnPerCallGate",
        "testConfirmationNamesTheExactSourceNameAndByteCount",
        "testUserDeclineIsNotConvertedIntoApproval",
        "testDisabledGateAndVisuallyChangedMetadataCannotBeApproved",
        "testMainThreadConfirmationFailsFast",
        "testAgentCancellationReachesTheNativeConfirmationBeforeApproval",
        "testOnlyOneRealNonemptyPickerResultReportsSaved",
        "testEmptyPickerResultFailsInsteadOfPretendingToSave",
        "testForeignPickerCannotCompleteTheOperation",
        "testUserCancellationHasOneCancelledResultAndPreservesTheSource",
        "testCancellationBeforeStartCannotPresentOrLaterSave",
        "testUnansweredPickerTimesOutAndIgnoresLateSuccess",
        "testSceneBackgroundCancelsThePickerAndLateCallbacks",
        "testTurningOffTheCapabilityWhilePickerIsOpenRevokesTheOperation",
        "testInactiveAppAndFailedPresentationNeverReportSaved",
        "testTwoExportsCannotStackPickers",
        "testPickerWaitsForTheConfirmationDismissTransition",
        "testAStuckDismissTransitionFailsWithoutPresenting",
        "testNativeSymlinkOrMismatchedNameCannotReachThePicker",
    ),
    "DSHCallConfirmationTests": (
        "testEveryOutcomeReachesTheActivityRecord",
        "testTestHooksShortCircuitWithoutShowingAnything",
        "testConfirmingFromABackgroundQueueDoesNotDeadlock",
        "testEveryOutcomeMapsToAnActionableResponse",
        "testConcurrentConfirmationsDoNotStack",
        "testCancellingPendingConfirmationDismissesOnlyItsOwnedAlertOnce",
        "testCancellationIsRecheckedBeforeAllowEvenBeforeTheNextPoll",
        "testBackgroundCancelsCancellableConfirmationAndPreservesUnrelatedLegacyPrompt",
        "testPeriodicCancellationEndsAPendingConfirmationWithoutWaitingForItsDeadline",
        "testTimeoutRejectsALateAllowAndDoesNotResolveTwice",
        "testLegacyPromptWithoutCancellationCheckStillAllowsAndDeclines",
        "testCancellationTakesPrecedenceOverTheAutomaticApprovalTestHook",
        "testCancellationResponseDoesNotPretendTheUserDeclinedOrInviteRetry",
    ),
}
LEGACY_CONFIRMATION = EXPECTED["DSHCallConfirmationTests"][:5]
# Column order varies between real result bundles. Names and types are fixed.
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


class GateError(RuntimeError):
    pass


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def required_identities():
    identities = [test_class + "/" + method
                  for test_class, methods in EXPECTED.items() for method in methods]
    if len(identities) != 51 or len(set(identities)) != 51:
        raise GateError("The fixed required selector list must contain exactly 51 unique tests")
    return identities


def verify_sources(root):
    required_identities()
    sources = []
    for test_class, methods in EXPECTED.items():
        path = Path(root) / "tests/DSHTests" / (test_class + ".m")
        if not path.is_file() or path.is_symlink():
            raise GateError("Required Native test source is absent or a symlink: " + test_class)
        content = path.read_text(encoding="utf-8")
        found = re.findall(r"^- \(void\)(test\w+)\s*(?:\{|$)", content, re.MULTILINE)
        if Counter(found) != Counter(methods):
            raise GateError("Native source selectors differ from the fixed required list: " + test_class)
        if re.search(r"\b(?:XCTSkip|XCTSkipIf|XCTSkipUnless|XCTExpectFailure)\s*\(", content):
            raise GateError("Required Native sources contain a skip or expected-failure directive: " + test_class)
        sources.append({"path": str(path.relative_to(root)), "sha256": digest(path), "selectors": len(found)})
    return sources


def select_bundle(results_dir):
    bundles = list(Path(results_dir).glob("DSH-unit-*.xcresult"))
    if len(bundles) != 1:
        raise GateError("Expected exactly one completed DSH-unit-*.xcresult bundle")
    return bundles[0]


def inspect_database(bundle):
    bundle = Path(bundle)
    database = bundle / "database.sqlite3"
    if (not bundle.is_dir() or bundle.is_symlink() or not database.is_file()
            or database.is_symlink() or not 0 < database.stat().st_size <= 512 * 1024 * 1024):
        raise GateError("Missing, unsafe or oversized xcresult SQLite database")
    # Completed xcresult bundles must not depend on an uncheckpointed writer.
    if any(database.with_name(database.name + suffix).exists() for suffix in ("-wal", "-journal")):
        raise GateError("xcresult SQLite still has a writer journal")
    before = digest(database)
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        connection.execute("PRAGMA query_only=ON")
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise GateError("xcresult SQLite integrity check failed")
        schema_sql = {}
        for table, expected in SCHEMA.items():
            row = connection.execute("SELECT type,sql FROM sqlite_master WHERE name=?", (table,)).fetchall()
            if len(row) != 1 or row[0][0] != "table":
                raise GateError("Unrecognized xcresult table: " + table)
            columns = {column[1]: column[2].upper() for column in connection.execute('PRAGMA table_info("' + table + '")')}
            if columns != expected:
                raise GateError("Unrecognized xcresult schema: " + table)
            schema_sql[table] = row[0][1]
        if connection.execute("SELECT count(*) FROM ExpectedFailures").fetchone()[0] != 0:
            raise GateError("Expected failures are present in the Native unit result bundle")
        runs = connection.execute("SELECT tc.identifier,tc.name,tr.result,tr.skipNotice_fk,tr.duration "
                                  "FROM TestCaseRuns tr JOIN TestCases tc ON tc.rowid=tr.testCase_fk").fetchall()
        if len(runs) != connection.execute("SELECT count(*) FROM TestCaseRuns").fetchone()[0]:
            raise GateError("xcresult contains orphaned test runs")
    if digest(database) != before:
        raise GateError("xcresult SQLite changed during inspection")
    identities = Counter(row[0] for row in runs)
    required = required_identities()
    outcomes = []
    for identity in required:
        own = [row for row in runs if row[0] == identity]
        if identities[identity] != 1:
            raise GateError("Required Native XCTest is absent or repeated: " + identity)
        name, result, skip_notice, duration = own[0][1:]
        if name != identity.split("/", 1)[1] or result != "Success" or skip_notice is not None:
            raise GateError("Required Native XCTest did not execute as an unconditional Success: " + identity)
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            raise GateError("Required Native XCTest has invalid execution duration: " + identity)
        outcomes.append({"identity": identity, "result": result, "duration_seconds": duration})
    if any(row[2] not in ("Success", "Failure", "Skipped") for row in runs):
        raise GateError("Unrecognized XCTest outcome in unit bundle")
    return {"bundle": str(bundle), "database_sha256": before, "schema_sql": schema_sql,
            "unit_run_count": len(runs), "required": outcomes,
            "new_native_passed": 46, "original_confirmation_passed": 5,
            "required_failed": 0, "required_skipped": 0, "expected_failures": 0}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--xcresult", type=Path)
    choice.add_argument("--results-dir", type=Path)
    parser.add_argument("--json-output", type=Path, required=True)
    args = parser.parse_args(argv)
    receipt = {"schema": 1, "gate": "required-workspace-export-native-tests", "passed": False,
               "github_sha": os.environ.get("GITHUB_SHA"), "github_run_id": os.environ.get("GITHUB_RUN_ID"),
               "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
               "limits": ["This reads real XCTest results; it does not prove an iPad Files-provider save."]}
    try:
        receipt["source_files"] = verify_sources(ROOT)
        bundle = args.xcresult if args.xcresult else select_bundle(args.results_dir)
        receipt.update(inspect_database(bundle))
        receipt["passed"] = True
    except (GateError, OSError, sqlite3.Error, UnicodeError) as error:
        receipt["failure"] = str(error)
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with args.json_output.open("x", encoding="utf-8") as output:
            json.dump(receipt, output, ensure_ascii=False, indent=2, allow_nan=False)
            output.write("\n")
    except (OSError, ValueError) as error:
        print("error: could not write a fresh Native test gate receipt: " + str(error), file=sys.stderr)
        return 1
    if not receipt["passed"]:
        print("error: required Native XCTest gate failed: " + receipt["failure"], file=sys.stderr)
        return 1
    print("ok: 46 new Native XCTests and five existing confirmation tests each executed exactly once as Success; 0 failed/skipped/expected-failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
