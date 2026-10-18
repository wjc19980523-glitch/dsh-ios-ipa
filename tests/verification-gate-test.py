#!/usr/bin/env python3
"""Offline archive-gate regressions: fake API, monotonic clock and sleep only."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verification_gate", ROOT / "scripts/check-verification-gate.py")
gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gate
SPEC.loader.exec_module(gate)

ENVIRONMENT = {
    "GITHUB_REPOSITORY": "owner/repository",
    "GITHUB_RUN_ID": "12345",
    "GITHUB_RUN_ATTEMPT": "2",
    "GITHUB_SHA": "a" * 40,
    "GITHUB_API_URL": "https://api.github.com",
    "VERIFY_JOB_NAME": "Verify guest image boots and dsh serves (macos-26)",
    "GITHUB_TOKEN": "synthetic-token-for-offline-tests",
}


def job(**overrides):
    value = {"id": 71, "run_id": 12345, "run_attempt": 2, "head_sha": "a" * 40,
             "name": ENVIRONMENT["VERIFY_JOB_NAME"], "status": "completed", "conclusion": "success"}
    value.update(overrides)
    return value


def payload(*jobs):
    return {"total_count": len(jobs), "jobs": list(jobs)}


class FakeClock:
    def __init__(self):
        self.now = 0.0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, duration):
        self.sleeps.append(duration)
        self.now += duration


class FakeFetch:
    def __init__(self, *results):
        self.results = list(results)
        self.calls = []

    def __call__(self, url, timeout):
        self.calls.append((url, timeout))
        if not self.results:
            raise AssertionError("unexpected API query")
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        if callable(result):
            return result()
        return copy.deepcopy(result)


class VerificationGateTests(unittest.TestCase):
    def setUp(self):
        self.identity = gate.configuration(ENVIRONMENT)
        self.clock = FakeClock()

    def wait(self, fetch, **options):
        return gate.wait_for_verification(self.identity, fetch, clock=self.clock,
                                          sleep=self.clock.sleep, **options)

    def test_current_attempt_exact_sha_success_permits_archive_immediately(self):
        fetch = FakeFetch(payload(job(), job(id=72, name="Test DSH (optional IPA) (macos-26)",
                                           status="in_progress", conclusion=None)))
        self.assertEqual(self.wait(fetch), 71)
        self.assertEqual(self.clock.sleeps, [])
        self.assertEqual(fetch.calls, [("https://api.github.com/repos/owner/repository/actions/"
                                       "runs/12345/attempts/2/jobs?per_page=100", 15)])

    def test_known_pending_states_wait_without_mutating_jobs_then_succeed(self):
        for status in sorted(gate.PENDING_STATUSES):
            with self.subTest(status=status):
                self.clock = FakeClock()
                pending = payload(job(status=status, conclusion=None))
                unchanged = copy.deepcopy(pending)
                fetch = FakeFetch(pending, payload(job()))
                self.assertEqual(self.wait(fetch), 71)
                self.assertEqual(self.clock.sleeps, [15])
                self.assertEqual(pending, unchanged)

    def test_failure_cancel_timeout_skipped_and_unknown_conclusions_deny(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", "neutral",
                           "action_required", "stale", "startup_failure", "unknown", None, ""):
            with self.subTest(conclusion=conclusion):
                fetch = FakeFetch(payload(job(conclusion=conclusion)))
                with self.assertRaises(gate.GateDenied):
                    self.wait(fetch)
                self.assertEqual(len(fetch.calls), 1)
                self.assertEqual(self.clock.sleeps, [])

    def test_wrong_run_attempt_sha_and_missing_identity_deny_without_retry(self):
        for key, values in (("run_id", (54321, "12345", True, None)),
                            ("run_attempt", (1, 3, "2", True, None)),
                            ("head_sha", ("b" * 40, "", None))):
            for value in values:
                with self.subTest(key=key, value=value):
                    fetch = FakeFetch(payload(job(**{key: value})))
                    with self.assertRaises(gate.GateDenied):
                        self.wait(fetch)
                    self.assertEqual(len(fetch.calls), 1)

    def test_mismatched_unrelated_job_also_rejects_mixed_attempt_response(self):
        with self.assertRaises(gate.GateDenied):
            self.wait(FakeFetch(payload(job(), job(id=72, name="App tests", run_attempt=1))))

    def test_exact_runner_name_is_required_and_prefix_alone_cannot_pass(self):
        for name in ("Verify guest image boots and dsh serves (xcode-27)",
                     "Verify guest image boots and dsh serves (macos-26) copied", "App tests"):
            with self.subTest(name=name), self.assertRaises(gate.GateDenied):
                self.wait(FakeFetch(payload(job(name=name))))

    def test_two_verification_jobs_are_ambiguous_even_with_one_exact_match(self):
        for second_name in (ENVIRONMENT["VERIFY_JOB_NAME"],
                            "Verify guest image boots and dsh serves (xcode-27)"):
            with self.subTest(name=second_name), self.assertRaises(gate.GateDenied):
                self.wait(FakeFetch(payload(job(), job(id=72, name=second_name))))

    def test_missing_duplicate_boolean_and_untyped_job_identities_deny(self):
        invalid = [payload(), payload(job(), job()), payload(job(id=True)), payload(job(id="71")),
                   payload(job(id=0)), payload(job(name=None)), payload(None)]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(gate.GateDenied):
                self.wait(FakeFetch(value))

    def test_incomplete_pagination_and_malformed_api_shapes_deny(self):
        invalid = [{}, [], None, {"total_count": True, "jobs": [job()]},
                   {"total_count": 2, "jobs": [job()]}, {"total_count": 0, "jobs": [job()]},
                   {"total_count": 101, "jobs": [job()]}, {"total_count": 1, "jobs": {}},
                   payload(*[job(id=index + 1, name="App tests") for index in range(101)])]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(gate.GateDenied):
                self.wait(FakeFetch(value))

    def test_unknown_or_inconsistent_status_never_grants_permission(self):
        for status, conclusion in (("unknown", None), (None, None), ({}, None),
                                    ("queued", "success"), ("in_progress", "failure"),
                                    ("completed", {})):
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(gate.GateDenied):
                self.wait(FakeFetch(payload(job(status=status, conclusion=conclusion))))

    def test_api_failure_fails_closed_immediately_without_retry_or_sleep(self):
        fetch = FakeFetch(OSError("sensitive response body"), payload(job()))
        with self.assertRaisesRegex(gate.GateDenied, "unable to read"):
            self.wait(fetch)
        self.assertEqual(len(fetch.calls), 1)
        self.assertEqual(self.clock.sleeps, [])

    def test_pending_job_identity_cannot_be_replaced_by_another_success(self):
        fetch = FakeFetch(payload(job(status="in_progress", conclusion=None)), payload(job(id=72)))
        with self.assertRaisesRegex(gate.GateDenied, "identity changed"):
            self.wait(fetch)
        self.assertEqual(self.clock.sleeps, [15])
        self.assertEqual(len(fetch.calls), 2)

    def test_pending_then_failed_job_is_not_retried_until_a_success_appears(self):
        fetch = FakeFetch(payload(job(status="queued", conclusion=None)),
                          payload(job(conclusion="failure")), payload(job()))
        with self.assertRaisesRegex(gate.GateDenied, "without success"):
            self.wait(fetch)
        self.assertEqual(self.clock.sleeps, [15])
        self.assertEqual(len(fetch.calls), 2)

    def test_pending_verification_deadline_denies_without_query_after_expiry(self):
        pending = payload(job(status="in_progress", conclusion=None))
        fetch = FakeFetch(pending, pending, payload(job()))
        with self.assertRaisesRegex(gate.GateDenied, "deadline"):
            self.wait(fetch, max_wait=30)
        self.assertEqual(self.clock.sleeps, [15, 15])
        self.assertEqual(len(fetch.calls), 2)

    def test_last_http_timeout_and_sleep_are_limited_to_remaining_budget(self):
        pending = payload(job(status="queued", conclusion=None))
        fetch = FakeFetch(pending, pending)
        with self.assertRaisesRegex(gate.GateDenied, "deadline"):
            self.wait(fetch, max_wait=23)
        self.assertEqual([timeout for _, timeout in fetch.calls], [15, 8])
        self.assertEqual(self.clock.sleeps, [15, 8])

    def test_success_returned_at_or_after_deadline_is_rejected(self):
        for elapsed in (30, 31):
            with self.subTest(elapsed=elapsed):
                self.clock = FakeClock()
                def delayed_success():
                    self.clock.now = elapsed
                    return payload(job())
                with self.assertRaisesRegex(gate.GateDenied, "deadline"):
                    self.wait(FakeFetch(delayed_success), max_wait=30)

    def test_nonfinite_or_backwards_clock_never_permits_archive(self):
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value):
                self.clock.now = value
                with self.assertRaises(gate.GateDenied):
                    self.wait(FakeFetch(payload(job())))
        self.clock.now = 10
        def backwards_success():
            self.clock.now = 9
            return payload(job())
        with self.assertRaises(gate.GateDenied):
            self.wait(FakeFetch(backwards_success))

    def test_wait_budget_cannot_exceed_ten_minutes_or_use_unbounded_values(self):
        for options in ({"max_wait": 601}, {"max_wait": 0}, {"max_wait": float("nan")},
                        {"poll_interval": 0}, {"poll_interval": float("inf")}):
            with self.subTest(options=options), self.assertRaises(gate.GateDenied):
                self.wait(FakeFetch(payload(job())), **options)


class ConfigurationAndTransportTests(unittest.TestCase):
    def test_required_environment_and_exact_name_are_validated_without_network(self):
        for key in ENVIRONMENT.keys() - {"GITHUB_TOKEN"}:
            with self.subTest(key=key):
                environment = dict(ENVIRONMENT)
                del environment[key]
                with self.assertRaises(gate.GateDenied):
                    gate.configuration(environment)
        for key, value in (("GITHUB_REPOSITORY", "owner/../repository"),
                           ("GITHUB_RUN_ATTEMPT", "0"), ("GITHUB_RUN_ID", "1?else=2"),
                           ("GITHUB_SHA", "a" * 39), ("VERIFY_JOB_NAME", "arbitrary tests")):
            with self.subTest(key=key), self.assertRaises(gate.GateDenied):
                gate.configuration({**ENVIRONMENT, key: value})

    def test_api_endpoint_requires_https_and_rejects_credentials_query_and_fragment(self):
        for url in ("http://api.github.com", "https://user:secret@api.github.com",
                    "https://api.github.com?token=secret", "https://api.github.com#fragment",
                    "https://api.github.com:invalid", "https://api.github.com\nother"):
            with self.subTest(url=url), self.assertRaises(gate.GateDenied):
                gate.configuration({**ENVIRONMENT, "GITHUB_API_URL": url})
        identity = gate.configuration({**ENVIRONMENT, "GITHUB_API_URL": "https://github.example/api/v3/"})
        self.assertTrue(identity.jobs_url.startswith("https://github.example/api/v3/repos/owner/repository/"))

    def test_transport_uses_get_and_header_only_token_with_finite_response_limit(self):
        calls = []
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *unused): return None
            def read(self, limit):
                calls.append(("limit", limit))
                return json.dumps(payload(job())).encode()
        class Opener:
            def open(self, request, timeout):
                calls.append((request, timeout))
                return Response()
        reader = gate.GitHubJobsReader(ENVIRONMENT["GITHUB_TOKEN"], opener=Opener())
        identity = gate.configuration(ENVIRONMENT)
        self.assertEqual(reader(identity.jobs_url, 7), payload(job()))
        request, timeout = calls[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.get_header("Authorization"), "Bearer " + ENVIRONMENT["GITHUB_TOKEN"])
        self.assertNotIn(ENVIRONMENT["GITHUB_TOKEN"], request.full_url)
        self.assertEqual(timeout, 7)
        self.assertEqual(calls[1], ("limit", gate.MAX_RESPONSE_BYTES + 1))

    def test_transport_refuses_redirects_and_missing_token(self):
        with self.assertRaises(gate.GateDenied):
            gate.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example")
        for token in ("", "token\nvalue", " token"):
            with self.subTest(token=token), self.assertRaises(gate.GateDenied):
                gate.GitHubJobsReader(token)

    def test_http_errors_invalid_json_and_oversized_bodies_are_private_failures(self):
        for status, body in ((403, b"private API error"), (200, b"not json: private body"),
                             (200, b"x" * (gate.MAX_RESPONSE_BYTES + 1))):
            with self.subTest(status=status):
                class Response:
                    def __enter__(self): return self
                    def __exit__(self, *unused): return None
                    def read(self, limit): return body
                response = Response()
                response.status = status
                class Opener:
                    def open(self, request, timeout): return response
                with self.assertRaises(gate.GateDenied) as failure:
                    gate.GitHubJobsReader("synthetic-token", opener=Opener())("https://api.github.com/jobs", 1)
                self.assertNotIn("private", str(failure.exception))
                self.assertNotIn("synthetic-token", str(failure.exception))

    def test_cli_failure_does_not_print_token_or_raw_api_exception(self):
        secret = ENVIRONMENT["GITHUB_TOKEN"]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = gate.main(ENVIRONMENT, fetch=FakeFetch(OSError(secret + " private-response")))
        self.assertEqual(result, 1)
        self.assertIn("denied", stderr.getvalue())
        self.assertNotIn(secret, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn("private-response", stdout.getvalue() + stderr.getvalue())

    def test_cli_success_returns_zero_and_has_only_numeric_and_commit_receipt(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = gate.main(ENVIRONMENT, fetch=FakeFetch(payload(job())))
        self.assertEqual(result, 0)
        self.assertIn("passed run=12345 attempt=2 job=71 sha=" + "a" * 40, stdout.getvalue())
        self.assertNotIn(ENVIRONMENT["GITHUB_TOKEN"], stdout.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
