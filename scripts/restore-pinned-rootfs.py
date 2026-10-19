#!/usr/bin/env python3
"""Restore only the fixed guest image from the verified Build 29 artifact.

Uses authenticated, read-only GitHub REST calls. The bearer token is sent only
to api.github.com; temporary download URLs and raw network errors are never
printed. No archive path is used as an extraction destination.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, HTTPRedirectHandler, build_opener
import zipfile


REPO = "wjc19980523-glitch/dsh-ios-ipa"
REPOSITORY_ID = 1412174788
SOURCE_SHA = "78e8500ed29afae5dc398846eca34480f7753f44"
ARTIFACT_ID = 12145352465
RUN_ID = 39148238106
API_ROOT = f"https://api.github.com/repos/{REPO}"
ARTIFACT_API = f"{API_ROOT}/actions/artifacts/{ARTIFACT_ID}"
RUN_API = f"{API_ROOT}/actions/runs/{RUN_ID}"
PINS = {
    "outer_bytes": 157683658,
    "outer_sha256": "48bd919324296d8e124e2ecef97be1519c9d991efb5ade90d274aa5bcc1e03a8",
    "ipa_bytes": 157658086,
    "ipa_sha256": "8932e9a4dfde26e8a033228c23f9dadd4d1a4377159d498fda9fdeeb1894177e",
    "root_bytes": 157427502,
    "root_sha256": "d3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0",
}
IPA_NAME = "DSH-1.1.0-build29-unsigned.ipa"
ROOT_MEMBER = "Payload/DSH.app/root.tar.gz"
CHUNK = 1024 * 1024
MAX_INNER_BYTES = 512 * 1024 * 1024
MAX_SECONDS = 300


class Rejected(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


def safe_download_url(value):
    require(isinstance(value, str) and len(value) <= 32768 and not any(ord(c) < 33 for c in value),
            "artifact redirect URL is invalid")
    parsed = urlsplit(value)
    host = parsed.hostname or ""
    require(parsed.scheme == "https" and parsed.port in (None, 443) and not parsed.username and
            not parsed.password and not parsed.fragment and
            (host.endswith(".blob.core.windows.net") or host.endswith(".actions.githubusercontent.com") or
             host == "objects.githubusercontent.com"), "artifact redirect is not an approved HTTPS storage host")
    return value


class GitHubReader:
    def __init__(self, token, opener=None):
        require(isinstance(token, str) and token and "\r" not in token and "\n" not in token,
                "GITHUB_TOKEN is missing or invalid")
        self.token = token
        self.opener = opener if opener is not None else build_opener(NoRedirect())

    def api(self, url, redirect=False):
        require(url in (ARTIFACT_API, RUN_API, ARTIFACT_API + "/zip"), "unexpected GitHub API endpoint")
        request = Request(url, headers={"Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "DSHIOS-pinned-rootfs-restore"})
        try:
            response = self.opener.open(request, timeout=60)
        except HTTPError as error:
            if redirect and error.code in (301, 302, 303, 307, 308):
                try:
                    return safe_download_url(error.headers.get("Location"))
                finally:
                    error.close()
            raise Rejected("GitHub metadata or artifact request failed") from None
        except Exception:
            raise Rejected("GitHub metadata or artifact connection failed") from None
        with response:
            require(not redirect and response.status == 200, "GitHub API response status differs")
            data = response.read(256 * 1024 + 1)
            require(len(data) <= 256 * 1024, "GitHub metadata exceeds its size bound")
            try:
                result = json.loads(data)
            except (ValueError, UnicodeError):
                raise Rejected("GitHub metadata is not valid JSON") from None
            require(isinstance(result, dict), "GitHub metadata must be an object")
            return result

    def download(self, url, destination, pins):
        url = safe_download_url(url)
        # Build an entirely new request without Authorization for each hop.
        for _ in range(4):
            request = Request(url, headers={"User-Agent": "DSHIOS-pinned-rootfs-restore"})
            try:
                response = self.opener.open(request, timeout=60)
                break
            except HTTPError as error:
                if error.code in (301, 302, 303, 307, 308):
                    try:
                        url = safe_download_url(error.headers.get("Location"))
                    finally:
                        error.close()
                    continue
                raise Rejected("artifact download request failed") from None
            except Exception:
                raise Rejected("artifact download connection failed") from None
        else:
            raise Rejected("artifact download exceeded its redirect bound")
        with response:
            require(response.status == 200, "artifact download status differs")
            length = response.headers.get("Content-Length")
            require(length is not None and length.isdecimal() and int(length) == pins["outer_bytes"],
                    "artifact download Content-Length differs from the fixed artifact")
            digest, count = bounded_copy(response, destination, pins["outer_bytes"])
        require(count == pins["outer_bytes"] and digest == pins["outer_sha256"],
                "artifact download bytes or SHA256 differ from the fixed artifact")


def validate_metadata(artifact, run, pins=PINS):
    require(artifact.get("id") == ARTIFACT_ID and artifact.get("name") == "DSH-unsigned-ipa" and
            artifact.get("size_in_bytes") == pins["outer_bytes"] and artifact.get("expired") is False and
            artifact.get("digest") == "sha256:" + pins["outer_sha256"] and
            artifact.get("url") == ARTIFACT_API and artifact.get("archive_download_url") == ARTIFACT_API + "/zip",
            "official artifact identity, digest, size or expiry differs")
    workflow = artifact.get("workflow_run", {})
    require(isinstance(workflow, dict) and workflow.get("id") == RUN_ID and
            workflow.get("repository_id") == REPOSITORY_ID and workflow.get("head_repository_id") == REPOSITORY_ID and
            workflow.get("head_sha") == SOURCE_SHA and workflow.get("head_branch") == "feature/plus-v1.1",
            "official artifact workflow identity differs")
    repository = run.get("repository", {})
    require(isinstance(repository, dict) and repository.get("id") == REPOSITORY_ID and repository.get("full_name") == REPO and
            run.get("id") == RUN_ID and run.get("run_attempt") == 1 and run.get("head_sha") == SOURCE_SHA and
            run.get("head_branch") == "feature/plus-v1.1" and run.get("status") == "completed" and
            run.get("conclusion") == "success" and run.get("event") == "workflow_dispatch" and
            run.get("path") == ".github/workflows/build-ipa.yml", "official source run is not the pinned successful attempt")
    try:
        expiry = datetime.fromisoformat(artifact["expires_at"].replace("Z", "+00:00"))
        require(expiry.tzinfo is not None and expiry > datetime.now(timezone.utc), "official artifact has expired")
    except (ValueError, TypeError, KeyError, AttributeError):
        raise Rejected("official artifact expiry is invalid") from None


def bounded_copy(stream, destination, maximum):
    digest, count, started = hashlib.sha256(), 0, time.monotonic()
    with destination.open("xb") as output:
        while True:
            require(time.monotonic() - started <= MAX_SECONDS, "bounded artifact transfer exceeded its deadline")
            block = stream.read(min(CHUNK, maximum - count + 1))
            if not block:
                break
            count += len(block)
            require(count <= maximum, "archive member or response exceeded its size bound")
            digest.update(block)
            output.write(block)
        output.flush()
        os.fsync(output.fileno())
    return digest.hexdigest(), count


def digest_file(path):
    require(stat.S_ISREG(path.lstat().st_mode), "existing file is not a regular file")
    digest, count = hashlib.sha256(), 0
    with path.open("rb") as stream:
        while True:
            block = stream.read(CHUNK)
            if not block:
                return digest.hexdigest(), count
            digest.update(block)
            count += len(block)


def valid_existing(output, pins=PINS):
    if not output.exists() and not output.is_symlink():
        return False
    digest, count = digest_file(output)
    require(digest == pins["root_sha256"] and count == pins["root_bytes"],
            "existing rootfs differs; refusing to overwrite it")
    return True


def checked_members(archive, outer=False):
    names, aliases, total = {}, set(), 0
    entries = archive.infolist()
    require(0 < len(entries) <= (2 if outer else 20000), "archive member count differs or exceeds its bound")
    for item in entries:
        name = item.filename
        require(item.orig_filename == name and name and not any(ord(c) < 32 or ord(c) == 127 for c in name) and
                not name.startswith("/") and "\\" not in name and ":" not in name and
                all(part not in ("", ".", "..") for part in name.rstrip("/").split("/")), "archive contains an unsafe member path")
        require(name not in names and name.casefold() not in aliases, "archive contains duplicate or colliding members")
        mode = stat.S_IFMT(item.external_attr >> 16)
        require(mode in (0, stat.S_IFREG, stat.S_IFDIR) and not item.flag_bits & 1 and
                item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "archive member type is unsupported")
        if not outer:
            require(name == "Payload/" or name == "Payload/DSH.app/" or name.startswith("Payload/DSH.app/"),
                    "inner IPA contains a member outside the expected app")
        total += item.file_size
        require(total <= MAX_INNER_BYTES, "archive uncompressed size exceeds its bound")
        names[name] = item
        aliases.add(name.casefold())
    return names


def materialize_from_zip(artifact_zip, output, pins=PINS):
    """Local hash/CRC verification and fixed-member restore, with no network.

    The caller establishes official metadata provenance separately. Tests may
    inject smaller pin sets; the CLI always uses the immutable production pins.
    """
    if valid_existing(output, pins):
        return {"reused_existing": True, "root_sha256": pins["root_sha256"], "root_bytes": pins["root_bytes"]}
    digest, count = digest_file(artifact_zip)
    require(digest == pins["outer_sha256"] and count == pins["outer_bytes"], "outer artifact file hash or size differs")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".dsh-pinned-rootfs-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        ipa_path, root_path = temporary / "source.ipa", temporary / "root.tar.gz"
        with zipfile.ZipFile(artifact_zip) as outer:
            names = checked_members(outer, outer=True)
            require(set(names) == {IPA_NAME, "ipa.sha256"}, "outer artifact must contain only its IPA and checksum")
            require(names[IPA_NAME].file_size == pins["ipa_bytes"] and names["ipa.sha256"].file_size <= 4096,
                    "outer artifact member size differs")
            with outer.open(IPA_NAME) as stream:
                digest, count = bounded_copy(stream, ipa_path, pins["ipa_bytes"])
            require(digest == pins["ipa_sha256"] and count == pins["ipa_bytes"], "inner IPA SHA256 or size differs")
            sidecar = outer.read("ipa.sha256").decode("ascii")
            require(re.fullmatch(re.escape(pins["ipa_sha256"]) + r"[ \t]+\*?(?:build/)?" + re.escape(IPA_NAME) + r"\r?\n?", sidecar) is not None,
                    "original IPA checksum sidecar differs")
        with zipfile.ZipFile(ipa_path) as inner:
            names = checked_members(inner)
            require(ROOT_MEMBER in names and names[ROOT_MEMBER].file_size == pins["root_bytes"], "fixed rootfs member is missing or has wrong size")
            for name, item in names.items():
                # Read every member to EOF, validating its original ZIP CRC.
                with inner.open(item) as stream:
                    if name == ROOT_MEMBER:
                        digest, count = bounded_copy(stream, root_path, pins["root_bytes"])
                        require(digest == pins["root_sha256"] and count == pins["root_bytes"], "fixed rootfs member SHA256 differs")
                    else:
                        while stream.read(CHUNK):
                            pass
        os.chmod(root_path, 0o644)
        # Same-filesystem hard-link publication is atomic and refuses an
        # existing destination; unlike replace(), it cannot clobber a race.
        try:
            os.link(root_path, output)
        except FileExistsError:
            require(valid_existing(output, pins), "rootfs destination changed before publication")
        if os.name != "nt":
            directory_fd = os.open(output.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    return {"reused_existing": False, "outer_sha256": pins["outer_sha256"], "outer_bytes": pins["outer_bytes"],
            "ipa_sha256": pins["ipa_sha256"], "ipa_bytes": pins["ipa_bytes"],
            "root_sha256": pins["root_sha256"], "root_bytes": pins["root_bytes"],
            "outer_and_inner_all_members_crc_verified": True, "fixed_member_only": ROOT_MEMBER,
            "atomic_no_overwrite_publication": True}


def restore(output, reader=None, pins=PINS):
    if valid_existing(output, pins):
        return {"reused_existing": True, "root_sha256": pins["root_sha256"], "root_bytes": pins["root_bytes"],
                "network_used": False, "metadata_checked_this_invocation": False}
    if reader is None:
        reader = GitHubReader(os.environ.get("GITHUB_TOKEN", ""))
    artifact, run = reader.api(ARTIFACT_API), reader.api(RUN_API)
    validate_metadata(artifact, run, pins)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".dsh-pinned-download-", dir=output.parent) as temporary:
        downloaded = Path(temporary) / "artifact.zip"
        url = reader.api(ARTIFACT_API + "/zip", redirect=True)
        reader.download(url, downloaded, pins)
        result = materialize_from_zip(downloaded, output, pins)
    return dict(result, network_used=True, metadata_checked_this_invocation=True,
                repository=REPO, artifact_id=ARTIFACT_ID, source_run_id=RUN_ID, source_run_attempt=1, source_sha=SOURCE_SHA)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/root.tar.gz"))
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    if args.json_output and args.json_output.resolve() == args.output.resolve():
        parser.error("receipt and rootfs destinations must differ")
    result = {"schema": 1, "accepted": False, "operations": {"remote_read_only": True, "rootfs_modified": False,
                "signing": False, "installation": False}}
    try:
        result.update(restore(args.output))
        result["accepted"] = True
    except Rejected as error:
        result["error"] = {"type": "Rejected", "reason": str(error)}
    except Exception:
        # Never interpolate a raw HTTP exception: it may contain the signed URL.
        result["error"] = {"type": "LocalOrTransportFailure", "reason": "pinned rootfs restore failed closed"}
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if result["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
