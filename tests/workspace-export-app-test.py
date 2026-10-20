#!/usr/bin/env python3
"""Portable positive/negative tests for the strict archive inclusion gate.

These synthetic archives do not replace XCTest or actual Build 30 inspection.
Only the test module's rootfs constants are replaced with a small fixture.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("workspace_app_gate", ROOT / "scripts/check-workspace-export-app.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
PINNED_ROOT_SHA = GATE.ROOTFS_SHA256
PINNED_ROOT_BYTES = GATE.ROOTFS_BYTES


def macho(platform=2, minimum=0x100000, classes=None, signed=False, cpu=0x0100000C, classlist_bytes=16):
    classes = sorted(GATE.NATIVE_CLASSES) if classes is None else classes
    names = b"\0".join(name.encode("ascii") for name in classes) + b"\0"
    version = struct.pack("<IIIIII", 0x32, 24, platform, minimum, 0x1A0500, 0)
    segment_length = 72 + 2 * 80
    signature = struct.pack("<IIII", 0x1D, 16, 0, 1) if signed else b""
    command_bytes = len(version) + segment_length + len(signature)
    names_offset = 32 + command_bytes
    pointers_offset = names_offset + len(names)
    pointers = b"\0" * classlist_bytes
    segment = struct.pack("<II16sQQQQIIII", 0x19, segment_length, b"__TEXT", 0, 0,
                          names_offset, len(names) + len(pointers), 0, 0, 2, 0)
    section = lambda name, start, size: struct.pack("<16s16sQQIIIIIIII", name, b"__TEXT", 0, size,
                                                   start, 0, 0, 0, 0, 0, 0, 0)
    segment += section(b"__objc_classname", names_offset, len(names))
    segment += section(b"__objc_classlist", pointers_offset, len(pointers))
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 2, 2 + bool(signed), command_bytes, 0, 0)
    return header + version + segment + signature + names + pointers


class ArchiveGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = tempfile.TemporaryDirectory(prefix="dsh-build30-gate-")
        cls.fixture = Path(cls.container.name)
        cls.source = cls.fixture / "source"
        cls.original = cls.fixture / "original.app"
        cls.original.mkdir()
        for bundle, names in GATE.BUNDLES.items():
            for name in names:
                relative = "app/" + bundle + "/" + name
                # Use the current checkout, including a newly added canonical
                # resource before commit. Do not normalize resource bytes: the
                # production gate must compare the exact archive/source pair.
                data = (ROOT / relative).read_bytes()
                src = cls.source / relative
                src.parent.mkdir(parents=True, exist_ok=True)
                src.write_bytes(data)
                dest = cls.original / bundle / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
        info = {"CFBundleIdentifier": GATE.APP_ID, "CFBundleVersion": "30", "CFBundleShortVersionString": "1.1.0",
                "CFBundleExecutable": "DSH", "CFBundlePackageType": "APPL", "MinimumOSVersion": "16.0"}
        (cls.original / "Info.plist").write_bytes(plistlib.dumps(info))
        (cls.original / "DSH").write_bytes(macho())
        root = b"synthetic fixed-rootfs fixture; not a real iOS or guest image\0"
        GATE.ROOTFS_SHA256 = hashlib.sha256(root).hexdigest()
        GATE.ROOTFS_BYTES = len(root)
        (cls.original / "root.tar.gz").write_bytes(root)
        (cls.original / "root.tar.gz.sha256").write_text(GATE.ROOTFS_SHA256 + "\n", encoding="ascii")

    @classmethod
    def tearDownClass(cls):
        GATE.ROOTFS_SHA256, GATE.ROOTFS_BYTES = PINNED_ROOT_SHA, PINNED_ROOT_BYTES
        cls.container.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case-", dir=self.fixture))
        self.app = self.case / "DSH.app"
        self.source_case = self.case / "source"
        shutil.copytree(self.original, self.app)
        shutil.copytree(self.source, self.source_case)

    def tearDown(self):
        shutil.rmtree(self.case)

    def check(self):
        return GATE.inspect(self.app, self.source_case)

    def change_info(self, key, value):
        path = self.app / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info[key] = value
        path.write_bytes(plistlib.dumps(info))

    def edit_manifest(self, edit):
        manifest = json.loads((self.app / "JobTracking.bundle/manifest.json").read_bytes())
        edit(manifest)
        data = json.dumps(manifest).encode()
        (self.app / "JobTracking.bundle/manifest.json").write_bytes(data)
        (self.source_case / "app/JobTracking.bundle/manifest.json").write_bytes(data)

    def write_onboarding_manifest(self, data):
        (self.app / "OnboardingInteraction.bundle/manifest.json").write_bytes(data)
        (self.source_case / "app/OnboardingInteraction.bundle/manifest.json").write_bytes(data)

    def edit_onboarding_manifest(self, edit):
        manifest = json.loads((self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes())
        edit(manifest)
        self.write_onboarding_manifest(json.dumps(manifest).encode())

    def test_actual_production_pins_and_fourteen_resource_contract(self):
        self.assertEqual(PINNED_ROOT_BYTES, 157427502)
        self.assertEqual(PINNED_ROOT_SHA, "d3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0")
        self.assertEqual(sum(map(len, GATE.BUNDLES.values())), 14)
        self.assertEqual(GATE.ONBOARDING_ORIGINAL_BYTES, 186641)
        self.assertEqual(GATE.ONBOARDING_ORIGINAL_SHA256, "7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa")
        self.assertEqual(GATE.ONBOARDING_BUILD29_BYTES, 191089)
        self.assertEqual(GATE.ONBOARDING_BUILD29_SHA256, "b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5")
        self.assertEqual(GATE.ONBOARDING_PATCHED_BYTES, 200500)
        self.assertEqual(GATE.ONBOARDING_PATCHED_SHA256, "d4f3634c7483237ad9627b0a4b06f6b5b04d538a5d96b304841afe09078bf9d5")

    def test_valid_synthetic_app_contains_both_native_classes_and_all_resources(self):
        result = self.check()
        self.assertEqual(result["bundled_resource_count"], 14)
        self.assertEqual(result["main_executable"]["slices"][0]["required_objc_class_names_found"], sorted(GATE.NATIVE_CLASSES))
        upgrade = result["onboarding_canonical_upgrade"]
        self.assertEqual(upgrade["replayed_sha256"], GATE.ONBOARDING_PATCHED_SHA256)
        self.assertEqual(upgrade["replacement_count"], 5)
        self.assertIs(upgrade["canonical_is_installable_guest_file"], False)

    def test_old_build_rejected(self):
        self.change_info("CFBundleVersion", "29")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_changed_bundle_identifier_rejected(self):
        self.change_info("CFBundleIdentifier", "com.example.other")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_changed_minimum_os_rejected(self):
        self.change_info("MinimumOSVersion", "17.0")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_simulator_executable_rejected(self):
        (self.app / "DSH").write_bytes(macho(platform=7))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_x86_executable_rejected(self):
        (self.app / "DSH").write_bytes(macho(cpu=0x01000007))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_macho_minimum_os_rejected(self):
        (self.app / "DSH").write_bytes(macho(minimum=0x0F0000))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_native_names_outside_objc_section_do_not_satisfy_inclusion(self):
        data = macho(classes=["OtherClass"]) + b"DSHWorkspaceExportStore\0DSHWorkspaceExportCapability\0"
        (self.app / "DSH").write_bytes(data)
        with self.assertRaises(GATE.Rejected): self.check()

    def test_empty_objc_class_list_rejected(self):
        (self.app / "DSH").write_bytes(macho(classlist_bytes=0))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_unrelated_non_ascii_class_metadata_does_not_break_required_class_matching(self):
        data = bytearray(macho())
        # Include a binary symbolic-name record in the class-name section.
        name_size_offset = 32 + 24 + 72 + 40
        old_size = struct.unpack_from("<Q", data, name_size_offset)[0]
        struct.pack_into("<Q", data, name_size_offset, old_size + 2)
        names_start = struct.unpack_from("<I", data, name_size_offset + 8)[0]
        data[names_start + old_size:names_start + old_size + 2] = b"\xc1\0"
        (self.app / "DSH").write_bytes(data)
        self.assertEqual(self.check()["bundled_resource_count"], 14)

    def test_main_code_signature_command_rejected(self):
        (self.app / "DSH").write_bytes(macho(signed=True))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_truncated_load_commands_rejected(self):
        (self.app / "DSH").write_bytes(macho()[:70])
        with self.assertRaises(GATE.Rejected): self.check()

    def test_objc_metadata_section_outside_slice_rejected(self):
        data = bytearray(macho())
        struct.pack_into("<I", data, 32 + 24 + 72 + 48, len(data) + 10)
        (self.app / "DSH").write_bytes(data)
        with self.assertRaises(GATE.Rejected): self.check()

    def test_rootfs_modified_same_size_rejected(self):
        path = self.app / "root.tar.gz"
        data = bytearray(path.read_bytes()); data[0] ^= 1; path.write_bytes(data)
        with self.assertRaises(GATE.Rejected): self.check()

    def test_rootfs_sidecar_mismatch_rejected(self):
        (self.app / "root.tar.gz.sha256").write_text("0" * 64, encoding="ascii")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_missing_new_guest_module_rejected(self):
        (self.app / "JobTracking.bundle/workspace-export.mjs").unlink()
        with self.assertRaises(GATE.Rejected): self.check()

    def test_guest_module_differs_from_exact_source_rejected(self):
        path = self.app / "JobTracking.bundle/workspace-export.mjs"
        path.write_bytes(path.read_bytes() + b"\n// unexpected content\n")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_untracked_cloud_draft_in_bundle_rejected(self):
        (self.app / "JobTracking.bundle/cloud-build.mjs").write_bytes(b"unapproved draft")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_manifest_hash_mismatch_rejected_even_when_source_matches(self):
        self.edit_manifest(lambda manifest: manifest["files"][0].update(sha256="0" * 64))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_manifest_cannot_redirect_a_resource_target(self):
        self.edit_manifest(lambda manifest: manifest["files"][0].update(target="/root/private/data"))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_old_guest_upgrade_hash_required(self):
        def edit(manifest):
            item = next(item for item in manifest["files"] if item["source"] == "job-tracking.mjs")
            item["previous_sha256"] = []
        self.edit_manifest(edit)
        with self.assertRaises(GATE.Rejected): self.check()

    def test_guest_index_patch_identity_required(self):
        self.edit_manifest(lambda manifest: manifest["patches"][0].update(patched_sha256="0" * 64))
        with self.assertRaises(GATE.Rejected): self.check()

    def test_removing_tool_registration_rejected_even_with_coherent_new_hash(self):
        path = self.app / "JobTracking.bundle/workspace-export.mjs"
        data = path.read_bytes().replace(b"name: 'file_export_from_workspace'", b"name: 'removed_tool'")
        path.write_bytes(data)
        (self.source_case / "app/JobTracking.bundle/workspace-export.mjs").write_bytes(data)
        def edit(manifest):
            item = next(item for item in manifest["files"] if item["source"] == "workspace-export.mjs")
            item["sha256"] = hashlib.sha256(data).hexdigest()
        self.edit_manifest(edit)
        with self.assertRaises(GATE.Rejected): self.check()

    def test_missing_onboarding_canonical_resource_rejected(self):
        (self.app / "OnboardingInteraction.bundle" / GATE.ONBOARDING_SOURCE).unlink()
        with self.assertRaisesRegex(GATE.Rejected, "missing or unexpected bundled resources"): self.check()

    def test_onboarding_cannot_include_an_additional_resource(self):
        (self.app / "OnboardingInteraction.bundle/foreign.js").write_bytes(b"unapproved")
        with self.assertRaisesRegex(GATE.Rejected, "missing or unexpected bundled resources"): self.check()

    def test_onboarding_canonical_hash_is_pinned_even_when_source_matches(self):
        for base in (self.app, self.source_case / "app"):
            path = base / "OnboardingInteraction.bundle" / GATE.ONBOARDING_SOURCE
            data = bytearray(path.read_bytes()); data[0] ^= 1; path.write_bytes(data)
        with self.assertRaisesRegex(GATE.Rejected, "Onboarding canonical bytes or hash differs"): self.check()

    def test_onboarding_canonical_declaration_has_only_fixed_source_and_hash(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        variants = [None, {"source": "session-backend-original.js", "sha256": GATE.ONBOARDING_ORIGINAL_SHA256},
                    {"source": GATE.ONBOARDING_SOURCE, "sha256": "0" * 64},
                    {"source": GATE.ONBOARDING_SOURCE, "sha256": GATE.ONBOARDING_ORIGINAL_SHA256, "target": "/root/user"}]
        for value in variants:
            with self.subTest(value=value):
                self.write_onboarding_manifest(valid)
                self.edit_onboarding_manifest(lambda m: m["patches"][0].update(original_source=value))
                with self.assertRaisesRegex(GATE.Rejected, "Onboarding canonical declaration differs"): self.check()
        self.write_onboarding_manifest(valid)
        self.edit_onboarding_manifest(lambda m: m["patches"][0].pop("original_source"))
        with self.assertRaisesRegex(GATE.Rejected, "Onboarding patch shape differs"): self.check()

    def test_onboarding_previous_whitelist_cannot_expand_or_accept_arbitrary_rollback(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for previous in ([], [GATE.ONBOARDING_ORIGINAL_SHA256], ["0" * 64], GATE.ONBOARDING_BUILD29_SHA256,
                         [GATE.ONBOARDING_BUILD29_SHA256, "0" * 64], [GATE.ONBOARDING_BUILD29_SHA256] * 2):
            with self.subTest(previous=previous):
                self.write_onboarding_manifest(valid)
                self.edit_onboarding_manifest(lambda m: m["patches"][0].update(previous_sha256=previous))
                with self.assertRaisesRegex(GATE.Rejected, "Onboarding previous-version whitelist differs"): self.check()

    def test_onboarding_cannot_redirect_to_another_package_or_user_file(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for target in ("/root/user/config", "/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js",
                       "/usr/local/lib/node_modules/@deepseek-ai/dsh-api-session-backend/lib/index.js",
                       GATE.ONBOARDING_TARGET + "/../client.js"):
            with self.subTest(target=target):
                self.write_onboarding_manifest(valid)
                self.edit_onboarding_manifest(lambda m: m["patches"][0].update(target=target))
                with self.assertRaisesRegex(GATE.Rejected, "Onboarding patch target or pinned identity differs"): self.check()

    def test_onboarding_canonical_must_never_be_installable_guest_file(self):
        self.edit_onboarding_manifest(lambda m: m.update(files=[{"source": GATE.ONBOARDING_SOURCE,
                                                               "target": "/root/user/copy.js"}]))
        with self.assertRaisesRegex(GATE.Rejected, "empty Guest-file contract differs"): self.check()

    def test_onboarding_rootfs_schema_and_root_shape_are_fixed(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for edit in (lambda m: m.update(schema=True), lambda m: m.update(schema=2),
                     lambda m: m.update(rootfs_sha256="0" * 64), lambda m: m.update(extra=True)):
            with self.subTest(edit=edit):
                self.write_onboarding_manifest(valid); self.edit_onboarding_manifest(edit)
                with self.assertRaises(GATE.Rejected): self.check()

    def test_onboarding_requires_one_exact_patch_shape(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for edit in (lambda m: m.update(patches=[]), lambda m: m["patches"].append(m["patches"][0]),
                     lambda m: m["patches"][0].update(extra="unapproved")):
            with self.subTest(edit=edit):
                self.write_onboarding_manifest(valid); self.edit_onboarding_manifest(edit)
                with self.assertRaises(GATE.Rejected): self.check()

    def test_onboarding_requires_all_five_exact_replacements(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for edit in (lambda m: m["patches"][0]["replacements"].pop(),
                     lambda m: m["patches"][0]["replacements"].append(m["patches"][0]["replacements"][-1])):
            self.write_onboarding_manifest(valid); self.edit_onboarding_manifest(edit)
            with self.assertRaisesRegex(GATE.Rejected, "Onboarding requires the three API patches"): self.check()

    def test_onboarding_replacement_match_count_is_strict_integer_one(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for value in (True, 0, 2, 1.0, "1"):
            with self.subTest(value=value):
                self.write_onboarding_manifest(valid)
                self.edit_onboarding_manifest(lambda m: m["patches"][0]["replacements"][0].update(count=value))
                with self.assertRaisesRegex(GATE.Rejected, "one exact match"): self.check()

    def test_onboarding_replacement_shape_and_find_are_validated(self):
        valid = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        for edit in (lambda r: r.update(extra=True), lambda r: r.update(find=""),
                     lambda r: r.update(find="no match for this fixture"), lambda r: r.update(replace=None)):
            self.write_onboarding_manifest(valid)
            self.edit_onboarding_manifest(lambda m: edit(m["patches"][0]["replacements"][0]))
            with self.assertRaises(GATE.Rejected): self.check()

    def test_onboarding_preserves_the_three_original_api_patches(self):
        def edit(manifest):
            replacement = manifest["patches"][0]["replacements"][0]
            replacement["replace"] += " "
        self.edit_onboarding_manifest(edit)
        with self.assertRaisesRegex(GATE.Rejected, "do not preserve the Build 29 API patch"): self.check()

    def test_onboarding_replayed_final_client_is_pinned(self):
        def edit(manifest):
            replacement = manifest["patches"][0]["replacements"][4]
            replacement["replace"] += " "
        self.edit_onboarding_manifest(edit)
        with self.assertRaisesRegex(GATE.Rejected, "Onboarding replay result differs"): self.check()

    def test_onboarding_cannot_declare_an_alternate_new_client_hash(self):
        self.edit_onboarding_manifest(lambda m: m["patches"][0].update(patched_sha256="0" * 64))
        with self.assertRaisesRegex(GATE.Rejected, "pinned identity differs"): self.check()

    def permissive_catch_candidate(self):
        # Exact prior 11b2c31 candidate, kept as an adverse resource fixture.
        # Do not require repository history in the shallow macOS CI checkout.
        manifest = json.loads((self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes())
        patch = manifest["patches"][0]
        patch["replacements"][4]["replace"] = (
            "\t\t\t\ttry {\n"
            "\t\t\t\t\tawait this.scope.set(WELCOME_NOTICE_ACK_FIELD, WELCOME_NOTICE_VERSION);\n"
            "\t\t\t\t} catch {\n"
            "\t\t\t\t\t// Derive the exact persisted version below; never assume a failed write saved.\n"
            "\t\t\t\t} finally {\n"
            "\t\t\t\t\tthis.saving = false;\n"
            "\t\t\t\t}")
        text = (self.app / "OnboardingInteraction.bundle" / GATE.ONBOARDING_SOURCE).read_bytes().decode("utf-8")
        for replacement in patch["replacements"]:
            self.assertEqual(text.count(replacement["find"]), replacement["count"])
            text = text.replace(replacement["find"], replacement["replace"])
        data = text.encode("utf-8")
        self.assertEqual(len(data), 200391)
        self.assertEqual(hashlib.sha256(data).hexdigest(), "08bca6d6bcc92bc16fde2daadb2d50469c5573d7f90180e74e147eb9fe5e9c1c")
        return manifest

    def test_prior_permissive_catch_candidate_rejected_even_when_source_agrees(self):
        manifest = self.permissive_catch_candidate()
        manifest["patches"][0]["patched_sha256"] = "08bca6d6bcc92bc16fde2daadb2d50469c5573d7f90180e74e147eb9fe5e9c1c"
        self.write_onboarding_manifest(json.dumps(manifest).encode())
        with self.assertRaisesRegex(GATE.Rejected, "pinned identity differs"): self.check()

    def test_permissive_catch_cannot_hide_behind_the_new_client_declaration(self):
        manifest = self.permissive_catch_candidate()
        self.write_onboarding_manifest(json.dumps(manifest).encode())
        with self.assertRaisesRegex(GATE.Rejected, "Onboarding replay result differs"): self.check()

    def test_onboarding_duplicate_json_keys_rejected_even_when_source_matches(self):
        data = (self.app / "OnboardingInteraction.bundle/manifest.json").read_bytes()
        self.write_onboarding_manifest(data.replace(b'"schema": 1', b'"schema": 1, "schema": 1', 1))
        with self.assertRaisesRegex(GATE.Rejected, "duplicate JSON key"): self.check()

    def test_embedded_profile_rejected(self):
        (self.app / "embedded.mobileprovision").write_bytes(b"unauthorized profile")
        with self.assertRaises(GATE.Rejected): self.check()

    def test_signature_resources_rejected(self):
        (self.app / "_CodeSignature").mkdir()
        with self.assertRaises(GATE.Rejected): self.check()

    def test_cli_missing_app_fails_closed_and_writes_failure_receipt(self):
        receipt = self.case / "receipt.json"
        process = subprocess.run([sys.executable, str(ROOT / "scripts/check-workspace-export-app.py"),
                                  "--app", str(self.case / "missing.app"), "--source-root", str(self.source_case),
                                  "--json-output", str(receipt)], capture_output=True, check=False)
        self.assertEqual(process.returncode, 1)
        self.assertIs(json.loads(receipt.read_text(encoding="utf-8"))["accepted"], False)

    def test_cli_refuses_to_write_a_receipt_inside_the_read_only_app(self):
        before = (self.app / "Info.plist").read_bytes()
        process = subprocess.run([sys.executable, str(ROOT / "scripts/check-workspace-export-app.py"),
                                  "--app", str(self.app), "--source-root", str(self.source_case),
                                  "--json-output", str(self.app / "Info.plist")], capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertEqual((self.app / "Info.plist").read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
