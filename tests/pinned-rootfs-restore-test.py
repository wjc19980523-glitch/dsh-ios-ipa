#!/usr/bin/env python3
"""Portable fault controls for pinned-artifact restore; no actual network."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
import warnings
import zipfile


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("pinned_rootfs_restore", ROOT / "scripts/restore-pinned-rootfs.py")
RESTORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESTORE)


def zipped(items):
    stream = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_STORED) as archive:
            for name, data in items:
                archive.writestr(name, data)
    return stream.getvalue()


def fixture(inner_items=None, sidecar=None):
    root = b"\0fixed guest bytes\xff\x80\0"
    inner = zipped(inner_items if inner_items is not None else [
        (RESTORE.ROOT_MEMBER, root), ("Payload/DSH.app/DSH", b"fixture executable")])
    ipa_hash = hashlib.sha256(inner).hexdigest()
    sidecar = sidecar if sidecar is not None else (ipa_hash + "  build/" + RESTORE.IPA_NAME + "\n").encode()
    outer = zipped([(RESTORE.IPA_NAME, inner), ("ipa.sha256", sidecar)])
    pins = {"outer_bytes": len(outer), "outer_sha256": hashlib.sha256(outer).hexdigest(),
            "ipa_bytes": len(inner), "ipa_sha256": ipa_hash,
            "root_bytes": len(root), "root_sha256": hashlib.sha256(root).hexdigest()}
    return outer, pins, root


def metadata(pins):
    artifact = {"id": RESTORE.ARTIFACT_ID, "name": "DSH-unsigned-ipa", "size_in_bytes": pins["outer_bytes"],
        "expired": False, "expires_at": "2099-01-01T00:00:00Z", "digest": "sha256:" + pins["outer_sha256"],
        "url": RESTORE.ARTIFACT_API, "archive_download_url": RESTORE.ARTIFACT_API + "/zip",
        "workflow_run": {"id": RESTORE.RUN_ID, "repository_id": RESTORE.REPOSITORY_ID,
            "head_repository_id": RESTORE.REPOSITORY_ID, "head_sha": RESTORE.SOURCE_SHA, "head_branch": "feature/plus-v1.1"}}
    run = {"id": RESTORE.RUN_ID, "run_attempt": 1, "head_sha": RESTORE.SOURCE_SHA,
        "head_branch": "feature/plus-v1.1", "status": "completed", "conclusion": "success",
        "event": "workflow_dispatch", "path": ".github/workflows/build-ipa.yml",
        "repository": {"id": RESTORE.REPOSITORY_ID, "full_name": RESTORE.REPO}}
    return artifact, run


class Response(io.BytesIO):
    status = 200
    def __init__(self, value, length=None):
        super().__init__(value)
        self.headers = {"Content-Length": str(len(value) if length is None else length)}


class FixtureReader:
    def __init__(self, outer, pins):
        self.outer, self.pins = outer, pins
        self.artifact, self.run = metadata(pins)
        self.calls = []
    def api(self, url, redirect=False):
        self.calls.append(url)
        if url == RESTORE.ARTIFACT_API: return copy.deepcopy(self.artifact)
        if url == RESTORE.RUN_API: return copy.deepcopy(self.run)
        if url == RESTORE.ARTIFACT_API + "/zip" and redirect:
            return "https://fixture.blob.core.windows.net/artifact?sig=never-log"
        raise AssertionError("unexpected endpoint")
    def download(self, url, destination, pins):
        self.calls.append("download-without-credentials")
        destination.write_bytes(self.outer)


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dsh-pinned-root-test-")
        self.directory = Path(self.temp.name)
        self.output = self.directory / "build/root.tar.gz"
        self.outer, self.pins, self.root = fixture()
        self.zip_path = self.directory / "artifact.zip"
        self.zip_path.write_bytes(self.outer)
    def tearDown(self): self.temp.cleanup()
    def materialize(self): return RESTORE.materialize_from_zip(self.zip_path, self.output, self.pins)
    def bad(self):
        with self.assertRaises((RESTORE.Rejected, zipfile.BadZipFile)):
            self.materialize()
        self.assertFalse(self.output.exists())

    def test_production_three_layer_pins_are_fixed(self):
        self.assertEqual(RESTORE.PINS["outer_bytes"], 157683658)
        self.assertEqual(RESTORE.PINS["ipa_bytes"], 157658086)
        self.assertEqual(RESTORE.PINS["root_bytes"], 157427502)
        self.assertEqual(RESTORE.PINS["root_sha256"], "d3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0")

    def test_valid_fixture_restores_only_exact_root_and_cleans_staging(self):
        result = self.materialize()
        self.assertEqual(self.output.read_bytes(), self.root)
        self.assertTrue(result["outer_and_inner_all_members_crc_verified"])
        self.assertEqual(list(self.output.parent.iterdir()), [self.output])

    def test_fixture_end_to_end_metadata_and_restore(self):
        reader = FixtureReader(self.outer, self.pins)
        result = RESTORE.restore(self.output, reader, self.pins)
        self.assertTrue(result["metadata_checked_this_invocation"])
        self.assertEqual(result["artifact_id"], RESTORE.ARTIFACT_ID)
        self.assertEqual(self.output.read_bytes(), self.root)

    def test_exact_existing_root_reuses_without_network(self):
        self.output.parent.mkdir(); self.output.write_bytes(self.root)
        reader = FixtureReader(self.outer, self.pins)
        self.assertFalse(RESTORE.restore(self.output, reader, self.pins)["network_used"])
        self.assertEqual(reader.calls, [])

    def test_wrong_existing_root_is_never_overwritten_or_downloaded(self):
        self.output.parent.mkdir(); self.output.write_bytes(b"existing user-owned bytes")
        reader = FixtureReader(self.outer, self.pins)
        with self.assertRaises(RESTORE.Rejected): RESTORE.restore(self.output, reader, self.pins)
        self.assertEqual(self.output.read_bytes(), b"existing user-owned bytes")
        self.assertEqual(reader.calls, [])

    def test_official_metadata_mutation_matrix_fails_before_download(self):
        mutations = [("artifact", "id", 9), ("artifact", "expired", True), ("artifact", "digest", "sha256:" + "0" * 64),
            ("artifact", "size_in_bytes", 1), ("artifact", "url", "https://evil.example/"),
            ("artifact", "expires_at", "2000-01-01T00:00:00Z"), ("run", "run_attempt", 2),
            ("run", "head_sha", "0" * 40), ("run", "head_branch", "main"), ("run", "conclusion", "failure")]
        for which, key, value in mutations:
            with self.subTest(which=which, key=key):
                reader = FixtureReader(self.outer, self.pins)
                getattr(reader, which)[key] = value
                with self.assertRaises(RESTORE.Rejected): RESTORE.restore(self.output, reader, self.pins)
                self.assertNotIn("download-without-credentials", reader.calls)
                self.assertFalse(self.output.exists())

    def test_wrong_artifact_workflow_repository_or_sha_rejected(self):
        for key, value in [("id", 1), ("head_sha", "0" * 40), ("repository_id", 0), ("head_repository_id", 0)]:
            with self.subTest(key=key):
                artifact, run = metadata(self.pins); artifact["workflow_run"][key] = value
                with self.assertRaises(RESTORE.Rejected): RESTORE.validate_metadata(artifact, run, self.pins)

    def test_archive_hash_and_size_must_match(self):
        self.zip_path.write_bytes(self.outer + b"trailing bytes")
        self.bad()

    def test_inner_ipa_hash_must_match(self):
        self.pins["ipa_sha256"] = "0" * 64
        self.bad()

    def test_root_member_hash_must_match(self):
        self.pins["root_sha256"] = "0" * 64
        self.bad()

    def test_bad_original_checksum_sidecar_rejected(self):
        self.outer, self.pins, _ = fixture(sidecar=b"0" * 64 + b"  file.ipa\n")
        self.zip_path.write_bytes(self.outer); self.bad()

    def test_missing_fixed_root_member_rejected(self):
        self.outer, self.pins, _ = fixture(inner_items=[("Payload/DSH.app/other", b"other")])
        self.zip_path.write_bytes(self.outer); self.bad()

    def test_inner_path_traversal_cannot_extract_anything(self):
        self.outer, self.pins, _ = fixture(inner_items=[(RESTORE.ROOT_MEMBER, self.root), ("../escape", b"bad")])
        self.zip_path.write_bytes(self.outer); self.bad()
        self.assertFalse((self.directory / "escape").exists())

    def test_duplicate_fixed_root_member_rejected(self):
        self.outer, self.pins, _ = fixture(inner_items=[(RESTORE.ROOT_MEMBER, self.root), (RESTORE.ROOT_MEMBER, self.root)])
        self.zip_path.write_bytes(self.outer); self.bad()

    def test_case_colliding_fixed_root_member_rejected(self):
        self.outer, self.pins, _ = fixture(inner_items=[(RESTORE.ROOT_MEMBER, self.root), (RESTORE.ROOT_MEMBER.upper(), self.root)])
        self.zip_path.write_bytes(self.outer); self.bad()

    def test_crc_corruption_in_an_unextracted_member_still_rejected(self):
        inner = bytearray(zipped([(RESTORE.ROOT_MEMBER, self.root), ("Payload/DSH.app/other", b"CRC negative data")]))
        with zipfile.ZipFile(io.BytesIO(inner)) as archive:
            item = archive.getinfo("Payload/DSH.app/other")
            name_size, extra_size = struct.unpack_from("<HH", inner, item.header_offset + 26)
            inner[item.header_offset + 30 + name_size + extra_size] ^= 1
        self.pins["ipa_bytes"] = len(inner); self.pins["ipa_sha256"] = hashlib.sha256(inner).hexdigest()
        outer = zipped([(RESTORE.IPA_NAME, inner), ("ipa.sha256", (self.pins["ipa_sha256"] + "  " + RESTORE.IPA_NAME + "\n").encode())])
        self.pins["outer_bytes"] = len(outer); self.pins["outer_sha256"] = hashlib.sha256(outer).hexdigest()
        self.zip_path.write_bytes(outer); self.bad()

    def test_output_race_does_not_overwrite_the_existing_file(self):
        original_link = RESTORE.os.link
        def race(source, destination):
            Path(destination).write_bytes(b"racing independent data")
            return original_link(source, destination)
        with patch.object(RESTORE.os, "link", race):
            with self.assertRaises(RESTORE.Rejected): self.materialize()
        self.assertEqual(self.output.read_bytes(), b"racing independent data")

    def test_bounded_copy_rejects_one_byte_beyond_declared_length(self):
        with self.assertRaises(RESTORE.Rejected):
            RESTORE.bounded_copy(io.BytesIO(b"12345"), self.directory / "copy", 4)

    def test_redirect_host_allowlist(self):
        for url in ["http://fixture.blob.core.windows.net/a", "https://evil.example/a", "https://api.github.com/a",
                    "https://user@fixture.blob.core.windows.net/a", "https://fixture.blob.core.windows.net:444/a",
                    "https://fixture.blob.core.windows.net/a#fragment"]:
            with self.subTest(url=url):
                with self.assertRaises(RESTORE.Rejected): RESTORE.safe_download_url(url)

    def test_token_sent_to_api_only_and_removed_from_all_storage_hops(self):
        requests = []
        artifact, run = metadata(self.pins)
        outer, pins = self.outer, self.pins
        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                if request.full_url == RESTORE.ARTIFACT_API: return Response(json.dumps(artifact).encode())
                if request.full_url == RESTORE.RUN_API: return Response(json.dumps(run).encode())
                if request.full_url == RESTORE.ARTIFACT_API + "/zip":
                    raise HTTPError(request.full_url, 302, "redirect", {"Location": "https://first.blob.core.windows.net/a?sig=secret"}, None)
                if request.full_url.startswith("https://first."):
                    raise HTTPError(request.full_url, 302, "redirect", {"Location": "https://second.blob.core.windows.net/a?sig=secret"}, None)
                return Response(outer)
        reader = RESTORE.GitHubReader("test-bearer-secret", Opener())
        result = RESTORE.restore(self.output, reader, pins)
        self.assertTrue(result["metadata_checked_this_invocation"])
        self.assertEqual(len(requests), 5)
        for request in requests:
            if request.full_url.startswith("https://api.github.com/"):
                self.assertEqual(request.get_header("Authorization"), "Bearer test-bearer-secret")
            else: self.assertIsNone(request.get_header("Authorization"))
        self.assertNotIn("sig=secret", json.dumps(result))
        self.assertNotIn("test-bearer-secret", json.dumps(result))

    def test_download_content_length_mismatch_rejected(self):
        class Opener:
            def open(inner_self, request, timeout): return Response(self.outer, len(self.outer) + 1)
        reader = RESTORE.GitHubReader("test", Opener())
        with self.assertRaises(RESTORE.Rejected):
            reader.download("https://fixture.blob.core.windows.net/a", self.directory / "download.zip", self.pins)

    def test_no_redirect_handler_refuses_automatic_credential_forwarding(self):
        handler = RESTORE.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, "redirect", {}, "https://evil.example/"))

    def test_cli_sanitizes_raw_transport_exception(self):
        stream = io.StringIO()
        with patch.object(sys, "argv", ["restore", "--output", str(self.output)]), \
                patch.object(RESTORE, "restore", side_effect=RuntimeError("https://x?sig=secret token=leaked")), \
                contextlib.redirect_stdout(stream):
            self.assertEqual(RESTORE.main(), 1)
        self.assertFalse(json.loads(stream.getvalue())["accepted"])
        self.assertNotIn("secret", stream.getvalue())
        self.assertNotIn("leaked", stream.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
