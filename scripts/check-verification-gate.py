#!/usr/bin/env python3
"""Permit archiving only after this run attempt's verification job succeeds."""
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass


MAX_WAIT_SECONDS = 600
POLL_SECONDS = 15
HTTP_TIMEOUT_SECONDS = 15
MAX_RESPONSE_BYTES = 1024 * 1024
VERIFICATION_PREFIX = "Verify guest image boots and dsh serves ("
PENDING_STATUSES = frozenset(("queued", "in_progress", "waiting", "pending", "requested"))


class GateDenied(Exception):
    """A fixed, non-sensitive reason why archiving must not proceed."""


@dataclass(frozen=True)
class RunIdentity:
    repository: str
    run_id: int
    attempt: int
    sha: str
    job_name: str
    jobs_url: str


def positive_integer(value):
    return type(value) is int and value > 0


def configuration(environment):
    repository = environment.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repository):
        raise GateDenied("invalid repository identity")
    if repository.split("/")[1] in (".", ".."):
        raise GateDenied("invalid repository identity")
    identifiers = []
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        value = environment.get(key, "")
        if not re.fullmatch(r"[1-9][0-9]{0,19}", value):
            raise GateDenied("invalid run or attempt identity")
        identifiers.append(int(value))
    sha = environment.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        raise GateDenied("invalid commit identity")
    job_name = environment.get("VERIFY_JOB_NAME", "")
    if (not job_name.startswith(VERIFICATION_PREFIX) or not job_name.endswith(")") or
            not 1 <= len(job_name[len(VERIFICATION_PREFIX):-1]) <= 128 or
            any(ord(character) < 32 for character in job_name)):
        raise GateDenied("invalid exact verification job name")
    api_url = environment.get("GITHUB_API_URL", "")
    try:
        api = urllib.parse.urlsplit(api_url)
        valid_api = (api.scheme == "https" and api.hostname and not api.username and
                     not api.password and not api.query and not api.fragment and
                     api.port != 0 and not any(ord(character) < 33 for character in api_url))
    except ValueError:
        valid_api = False
    if not valid_api:
        raise GateDenied("invalid GitHub API endpoint")
    run_id, attempt = identifiers
    owner, repo = (urllib.parse.quote(part, safe="") for part in repository.split("/"))
    jobs_url = (f"{api_url.rstrip('/')}/repos/{owner}/{repo}/actions/runs/{run_id}"
                f"/attempts/{attempt}/jobs?per_page=100")
    return RunIdentity(repository, run_id, attempt, sha.lower(), job_name, jobs_url)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        # Authorization must never follow an API redirect to another endpoint.
        raise GateDenied("GitHub API redirect refused")


class GitHubJobsReader:
    def __init__(self, token, opener=None):
        if not token or any(character.isspace() for character in token):
            raise GateDenied("missing or invalid GitHub token")
        self._token = token
        self._opener = opener if opener is not None else urllib.request.build_opener(NoRedirect())

    def __call__(self, url, timeout):
        # The token comes only from the environment and is sent only in this
        # request header. Never print headers, response bodies or exceptions.
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "DSH-verification-gate",
        }, method="GET")
        try:
            with self._opener.open(request, timeout=timeout) as response:
                if response.status != 200:
                    raise GateDenied("GitHub jobs API did not return success")
                payload = response.read(MAX_RESPONSE_BYTES + 1)
            if len(payload) > MAX_RESPONSE_BYTES:
                raise GateDenied("GitHub jobs API response exceeded the size limit")
            return json.loads(payload)
        except GateDenied:
            raise
        except Exception:
            raise GateDenied("unable to read the GitHub jobs API") from None


def verification_job(payload, identity):
    if (not isinstance(payload, dict) or type(payload.get("total_count")) is not int or
            not isinstance(payload.get("jobs"), list)):
        raise GateDenied("malformed GitHub jobs response")
    jobs = payload["jobs"]
    # This workflow has two jobs. Refuse an incomplete/paginated view instead
    # of assuming the unseen page cannot contain another verification job.
    if payload["total_count"] != len(jobs) or not 1 <= len(jobs) <= 100:
        raise GateDenied("incomplete or oversized GitHub jobs response")
    candidates = []
    seen = set()
    for job in jobs:
        if not isinstance(job, dict) or not positive_integer(job.get("id")) or job["id"] in seen:
            raise GateDenied("malformed or duplicate job identity")
        seen.add(job["id"])
        if (type(job.get("run_id")) is not int or job["run_id"] != identity.run_id or
                type(job.get("run_attempt")) is not int or job["run_attempt"] != identity.attempt or
                job.get("head_sha") != identity.sha):
            raise GateDenied("GitHub job run, attempt or commit identity mismatch")
        name = job.get("name")
        if not isinstance(name, str):
            raise GateDenied("malformed GitHub job name")
        if name.startswith(VERIFICATION_PREFIX):
            candidates.append(job)
    if len(candidates) != 1 or candidates[0]["name"] != identity.job_name:
        raise GateDenied("missing or ambiguous exact verification job")
    return candidates[0]


def wait_for_verification(identity, fetch, clock=time.monotonic, sleep=time.sleep,
                          max_wait=MAX_WAIT_SECONDS, poll_interval=POLL_SECONDS):
    if (not math.isfinite(max_wait) or not 0 < max_wait <= MAX_WAIT_SECONDS or
            not math.isfinite(poll_interval) or not 0 < poll_interval <= 20):
        raise GateDenied("invalid verification wait budget")
    started = clock()
    if not math.isfinite(started):
        raise GateDenied("invalid monotonic clock observation")
    deadline = started + max_wait
    last_time = started
    expected_job_id = None
    while True:
        now = clock()
        if not math.isfinite(now) or now < last_time:
            raise GateDenied("invalid monotonic clock observation")
        last_time = now
        remaining = deadline - now
        if remaining <= 0:
            raise GateDenied("verification wait deadline expired")
        try:
            payload = fetch(identity.jobs_url, min(HTTP_TIMEOUT_SECONDS, remaining))
        except Exception:
            # No API retry can turn an unknown observation into permission.
            raise GateDenied("unable to read the GitHub jobs API") from None
        observed = clock()
        if not math.isfinite(observed) or observed < last_time:
            raise GateDenied("invalid monotonic clock observation")
        last_time = observed
        if observed >= deadline:
            raise GateDenied("verification wait deadline expired")
        job = verification_job(payload, identity)
        if expected_job_id is not None and job["id"] != expected_job_id:
            raise GateDenied("verification job identity changed while waiting")
        expected_job_id = job["id"]
        status, conclusion = job.get("status"), job.get("conclusion")
        if not isinstance(status, str) or (conclusion is not None and not isinstance(conclusion, str)):
            raise GateDenied("unknown or inconsistent verification state")
        if status == "completed":
            if conclusion != "success":
                raise GateDenied("verification completed without success")
            return job["id"]
        if status not in PENDING_STATUSES or conclusion is not None:
            raise GateDenied("unknown or inconsistent verification state")
        sleep(min(poll_interval, deadline - observed))


def main(environment=None, fetch=None, clock=time.monotonic, sleep=time.sleep):
    environment = os.environ if environment is None else environment
    try:
        identity = configuration(environment)
        if fetch is None:
            fetch = GitHubJobsReader(environment.get("GITHUB_TOKEN", ""))
        print("verification gate: waiting for this run attempt's exact verification job", flush=True)
        job_id = wait_for_verification(identity, fetch, clock=clock, sleep=sleep)
        print(f"verification gate: passed run={identity.run_id} attempt={identity.attempt} "
              f"job={job_id} sha={identity.sha}", flush=True)
        return 0
    except GateDenied as error:
        print(f"verification gate: denied: {error}", file=sys.stderr, flush=True)
        return 1
    except KeyboardInterrupt:
        print("verification gate: denied: interrupted", file=sys.stderr, flush=True)
        return 1
    except Exception:
        print("verification gate: denied: unexpected local checker failure", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    if len(sys.argv) != 1:
        print("verification gate: denied: command-line arguments are not accepted", file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
