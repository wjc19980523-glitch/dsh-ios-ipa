#!/usr/bin/env python3
"""Read actual XCTest counts from an xcresult; never accept a build-only run."""
import argparse
import json
import pathlib
import subprocess
import sys


def summarize(data):
    counts = {}
    for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests"):
        value = data.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"xcresult summary has no valid {key}: schema or test execution failure")
        counts[key] = value
    executed = counts["totalTestCount"] - counts["skippedTests"]
    if executed < 0 or counts["passedTests"] + counts["failedTests"] != executed:
        raise ValueError("xcresult returned inconsistent test counts")
    return {
        "total": counts["totalTestCount"], "executed": executed,
        "passed": counts["passedTests"], "failed": counts["failedTests"],
        "skipped": counts["skippedTests"], "result": data.get("result", "Unknown"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--xcresult", type=pathlib.Path)
    source.add_argument("--summary-json", type=pathlib.Path, help="offline xcresulttool JSON fixture")
    parser.add_argument("--label", default="XCTest")
    parser.add_argument("--json-output", type=pathlib.Path)
    parser.add_argument("--markdown-output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.summary_json:
            data = json.loads(args.summary_json.read_text(encoding="utf-8"))
        else:
            raw = subprocess.check_output([
                "xcrun", "xcresulttool", "get", "test-results", "summary",
                "--path", str(args.xcresult), "--compact",
            ], text=True)
            data = json.loads(raw)
        result = summarize(data)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: {args.label}: unable to verify XCTest execution: {exc}", file=sys.stderr)
        return 1
    result["label"] = args.label
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    markdown = (
        f"### Simulator XCTest: {args.label}\n\n"
        "| Executed | Passed | Failed | Skipped | Result |\n"
        "|---:|---:|---:|---:|---|\n"
        f"| {result['executed']} | {result['passed']} | {result['failed']} | "
        f"{result['skipped']} | {result['result']} |\n\n"
    )
    print(markdown)
    if args.markdown_output:
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_output.write_text(markdown, encoding="utf-8")
    if result["executed"] == 0:
        print(f"error: {args.label}: zero tests executed (including an all-skipped run)", file=sys.stderr)
        return 1
    if result["failed"] or result["result"] != "Passed":
        print(f"error: {args.label}: XCTest did not pass", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
