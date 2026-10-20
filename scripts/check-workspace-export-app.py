#!/usr/bin/env python3
"""Read-only acceptance gate for the unsigned Build 30 iOS archive app.

Checks package inclusion, identity, the fixed guest image and exact source
resource bytes. Actual XCTest and iPad Files saving are separate evidence.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import struct
import sys


ROOTFS_SHA256 = "d3e055a6f98cc5d508a502aed88c3fca3c75f7b3217ee257d7e4773337d903a0"
ROOTFS_BYTES = 157427502
CHUNK_BYTES = 1024 * 1024
APP_ID = "com.xnuapp.dsh"
BUNDLES = {
    "SessionLifecycle.bundle": ("manifest.json", "session-backend-original.js",
        "session-checkpoint-core.mjs", "session-lifecycle-core.mjs", "session-lifecycle.mjs"),
    "WebFetchTransport.bundle": ("manifest.json", "web-fetch-transport.mjs"),
    "JobTracking.bundle": ("manifest.json", "development-tools.mjs", "job-ledger.mjs",
        "job-tracking.mjs", "workspace-export.mjs"),
    "OnboardingInteraction.bundle": ("manifest.json", "onboarding-client-original.js"),
}
NATIVE_CLASSES = {"DSHWorkspaceExportStore", "DSHWorkspaceExportCapability"}
ONBOARDING_SOURCE = "onboarding-client-original.js"
ONBOARDING_TARGET = "/usr/local/lib/node_modules/@deepseek-ai/dsh-client-ui-settings-models/lib/client.js"
ONBOARDING_ROOTFS_SHA256 = ROOTFS_SHA256
ONBOARDING_ORIGINAL_BYTES = 186641
ONBOARDING_ORIGINAL_SHA256 = "7674ed0ba2eef60fa7db91b4bf8cea4dc23e1f0a2f3dd1e6a2a67ad4c0d005fa"
ONBOARDING_BUILD29_BYTES = 191089
ONBOARDING_BUILD29_SHA256 = "b687b66611b19ac8ebb793bc128c4c56675fc0fc6c7df8f7ddae6195134339b5"
ONBOARDING_PATCHED_BYTES = 200500
ONBOARDING_PATCHED_SHA256 = "d4f3634c7483237ad9627b0a4b06f6b5b04d538a5d96b304841afe09078bf9d5"


class Rejected(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key in Onboarding manifest")
        result[key] = value
    return result


def inspect_onboarding(app):
    """Prove the pinned in-memory upgrade contract; never write a guest file."""
    directory = app / "OnboardingInteraction.bundle"
    manifest = json.loads(read_file(directory / "manifest.json", 4 * CHUNK_BYTES),
                          object_pairs_hook=unique_json_object)
    require(isinstance(manifest, dict) and
            set(manifest) == {"schema", "rootfs_sha256", "files", "patches"},
            "Onboarding manifest shape differs")
    require(type(manifest["schema"]) is int and manifest["schema"] == 1 and
            manifest["rootfs_sha256"] == ONBOARDING_ROOTFS_SHA256 and manifest["files"] == [],
            "Onboarding schema/rootfs or empty Guest-file contract differs")
    patches = manifest["patches"]
    require(isinstance(patches, list) and len(patches) == 1 and isinstance(patches[0], dict),
            "Onboarding requires exactly one patch")
    patch = patches[0]
    require(set(patch) == {"target", "original_sha256", "patched_sha256", "replacements",
                           "original_source", "previous_sha256"}, "Onboarding patch shape differs")
    require(patch["target"] == ONBOARDING_TARGET and
            patch["original_sha256"] == ONBOARDING_ORIGINAL_SHA256 and
            patch["patched_sha256"] == ONBOARDING_PATCHED_SHA256,
            "Onboarding patch target or pinned identity differs")
    require(patch["original_source"] == {"source": ONBOARDING_SOURCE, "sha256": ONBOARDING_ORIGINAL_SHA256},
            "Onboarding canonical declaration differs")
    require(patch["previous_sha256"] == [ONBOARDING_BUILD29_SHA256],
            "Onboarding previous-version whitelist differs")
    canonical = read_file(directory / ONBOARDING_SOURCE, 4 * CHUNK_BYTES)
    require(len(canonical) == ONBOARDING_ORIGINAL_BYTES and digest_bytes(canonical) == ONBOARDING_ORIGINAL_SHA256,
            "Onboarding canonical bytes or hash differs")
    replacements = patch["replacements"]
    require(isinstance(replacements, list) and len(replacements) == 5,
            "Onboarding requires the three API patches and two interaction/store patches")
    text = canonical.decode("utf-8")
    for index, replacement in enumerate(replacements):
        require(isinstance(replacement, dict) and set(replacement) == {"find", "replace", "count"},
                "Onboarding replacement shape differs")
        find, replace, count = replacement["find"], replacement["replace"], replacement["count"]
        require(isinstance(find, str) and bool(find) and isinstance(replace, str) and
                type(count) is int and count == 1, "Onboarding replacement must have one exact match")
        require(text.count(find) == count, "Onboarding replacement match count differs")
        text = text.replace(find, replace)
        encoded = text.encode("utf-8")
        require(len(encoded) <= 4 * CHUNK_BYTES, "Onboarding replacement exceeds its size bound")
        if index == 2:
            require(len(encoded) == ONBOARDING_BUILD29_BYTES and digest_bytes(encoded) == ONBOARDING_BUILD29_SHA256,
                    "Onboarding first three patches do not preserve the Build 29 API patch")
    require(len(encoded) == ONBOARDING_PATCHED_BYTES and digest_bytes(encoded) == ONBOARDING_PATCHED_SHA256,
            "Onboarding replay result differs from the pinned interaction/store client")
    return {"canonical_source": ONBOARDING_SOURCE, "canonical_bytes": len(canonical),
            "canonical_sha256": digest_bytes(canonical), "target": ONBOARDING_TARGET,
            "previous_sha256": [ONBOARDING_BUILD29_SHA256], "replacement_count": len(replacements),
            "replayed_bytes": len(encoded), "replayed_sha256": digest_bytes(encoded),
            "canonical_is_installable_guest_file": False,
            "limit": "resource/replay checks prove inclusion and upgrade inputs; actual Native XCTest proves execution separately"}


def regular_file(path, maximum=None):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), f"required path is not a regular file: {path.name}")
    require(maximum is None or info.st_size <= maximum, f"required file exceeds its size bound: {path.name}")
    return info


def read_file(path, maximum):
    info = regular_file(path, maximum)
    data = path.read_bytes()
    require(len(data) == info.st_size, f"file changed while being read: {path.name}")
    return data


def digest_file(path):
    info = regular_file(path)
    digest, count = hashlib.sha256(), 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
            count += len(chunk)
    require(count == info.st_size, f"file changed while being hashed: {path.name}")
    return digest.hexdigest(), count


def inspect_macho_slice(data, offset, size):
    require(size >= 32 and offset >= 0 and offset + size <= len(data), "invalid Mach-O slice range")
    magic = data[offset:offset + 4]
    require(magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"), "executable slice is not 64-bit Mach-O")
    endian = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
    _, cpu, subtype, filetype, ncmds, command_bytes, _, _ = struct.unpack_from(endian + "IIIIIIII", data, offset)
    require(cpu == 0x0100000C and filetype == 2, "main executable slice must be an arm64 executable")
    require(0 < ncmds <= 4096, "invalid Mach-O load command count")
    position = offset + 32
    command_end = position + command_bytes
    require(command_end <= offset + size, "Mach-O commands exceed the slice")
    versions, class_names, signatures = [], set(), []
    class_list_bytes = 0
    for _ in range(ncmds):
        require(position + 8 <= command_end, "truncated Mach-O command")
        command, command_size = struct.unpack_from(endian + "II", data, position)
        require(command_size >= 8 and command_size % 4 == 0 and position + command_size <= command_end,
                "invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(command_size >= 24, "truncated LC_BUILD_VERSION")
            platform, minimum, sdk, tools = struct.unpack_from(endian + "IIII", data, position + 8)
            require(command_size == 24 + tools * 8 and tools <= 256, "invalid build-version tool table")
            require(platform == 2, "main executable must target an iOS device, not a simulator")
            versions.append({"command": "LC_BUILD_VERSION", "platform": platform, "minimum": minimum, "sdk": sdk})
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, legacy device command.
            require(command_size == 16, "invalid legacy iOS version command")
            minimum, sdk = struct.unpack_from(endian + "II", data, position + 8)
            versions.append({"command": "LC_VERSION_MIN_IPHONEOS", "platform": 2, "minimum": minimum, "sdk": sdk})
        elif command == 0x1D:
            require(command_size >= 16, "truncated LC_CODE_SIGNATURE")
            signatures.append(True)
        elif command == 0x19:  # LC_SEGMENT_64
            require(command_size >= 72, "truncated LC_SEGMENT_64")
            section_count = struct.unpack_from(endian + "I", data, position + 64)[0]
            require(section_count <= 4096 and command_size == 72 + section_count * 80, "invalid Mach-O section table")
            for index in range(section_count):
                section = position + 72 + index * 80
                name = data[section:section + 16].split(b"\0")[0]
                section_size = struct.unpack_from(endian + "Q", data, section + 40)[0]
                section_offset = struct.unpack_from(endian + "I", data, section + 48)[0]
                if name in (b"__objc_classname", b"__objc_classlist"):
                    require(section_offset >= 32 + command_bytes and section_offset + section_size <= size,
                            "Objective-C metadata section exceeds the slice")
                    if name == b"__objc_classname":
                        raw = data[offset + section_offset:offset + section_offset + section_size]
                        # Swift's symbolic class-name records can contain
                        # non-ASCII bytes. Match only the two required complete
                        # C strings; do not decode unrelated metadata records.
                        class_names.update(value for value in NATIVE_CLASSES
                                           if b"\0" + value.encode("ascii") + b"\0" in b"\0" + raw)
                    else:
                        require(section_size % 8 == 0, "invalid Objective-C class pointer section")
                        class_list_bytes += section_size
        position += command_size
    require(position == command_end, "Mach-O command size/count mismatch")
    require(versions and all(item["minimum"] == 0x100000 for item in versions), "executable minimum iOS must be 16.0")
    require(not signatures, "main executable unexpectedly contains a code-signature command")
    require(class_list_bytes > 0 and NATIVE_CLASSES <= class_names, "required Native classes missing from Objective-C metadata")
    return {"architecture": "arm64", "cpu_type": cpu, "cpu_subtype": subtype,
            "offset": offset, "bytes": size, "build_versions": versions,
            "required_objc_class_names_found": sorted(NATIVE_CLASSES), "objc_class_list_bytes": class_list_bytes,
            "main_code_signature_present": False}


def inspect_macho(data):
    if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        slices = [inspect_macho_slice(data, 0, len(data))]
    else:
        formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                   b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
        require(data[:4] in formats and len(data) >= 8, "unknown main executable format")
        endian, fat64 = formats[data[:4]]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        record_bytes = 32 if fat64 else 20
        table_end = 8 + count * record_bytes
        require(1 <= count <= 32 and table_end <= len(data), "invalid fat architecture table")
        slices, ranges = [], []
        for index in range(count):
            cpu, subtype, start, length, alignment = struct.unpack_from(
                endian + ("IIQQII" if fat64 else "IIIII"), data, 8 + index * record_bytes)[:5]
            require(start >= table_end and alignment <= 31 and start % (1 << alignment) == 0, "invalid fat slice alignment")
            require(all(start + length <= a or start >= b for a, b in ranges), "overlapping fat slices")
            result = inspect_macho_slice(data, start, length)
            require(cpu == result["cpu_type"] and subtype == result["cpu_subtype"], "fat/thin CPU metadata differs")
            slices.append(result)
            ranges.append((start, start + length))
    return {"sha256": digest_bytes(data), "bytes": len(data), "slices": slices,
            "metadata_limit": "class metadata presence proves inclusion; actual Native XCTest establishes execution separately"}


def inspect_resources(app, source_root):
    records = []
    for bundle, required in BUNDLES.items():
        directory = app / bundle
        require(directory.is_dir() and not directory.is_symlink(), f"required resource bundle missing: {bundle}")
        actual = set()
        for path in directory.rglob("*"):
            require(not path.is_symlink(), f"symlink in resource bundle: {bundle}")
            if path.is_dir():
                continue
            require(path.is_file(), f"special file in resource bundle: {bundle}")
            actual.add(path.relative_to(directory).as_posix())
        require(actual == set(required), f"missing or unexpected bundled resources: {bundle}")
        for name in required:
            packaged = read_file(directory / name, 4 * CHUNK_BYTES)
            source = read_file(source_root / "app" / bundle / name, 4 * CHUNK_BYTES)
            require(packaged == source, f"packaged resource differs from checkout source: {bundle}/{name}")
            records.append({"member": f"{bundle}/{name}", "bytes": len(packaged), "sha256": digest_bytes(packaged)})
    manifest = json.loads(read_file(app / "JobTracking.bundle/manifest.json", 4 * CHUNK_BYTES))
    require(isinstance(manifest, dict), "JobTracking manifest must be a dictionary")
    files = manifest.get("files")
    required = set(BUNDLES["JobTracking.bundle"]) - {"manifest.json"}
    require(manifest.get("schema") == 1 and isinstance(files, list) and len(files) == 4,
            "JobTracking manifest requires schema 1 and exactly four files")
    require(all(isinstance(item, dict) for item in files) and {item.get("source") for item in files} == required,
            "JobTracking Guest resource whitelist differs")
    for item in files:
        name = item["source"]
        require(item.get("target") == "/usr/local/lib/dsh-plugins/dsh-host-bridge/" + name, "Guest install target differs")
        require(item.get("sha256") == digest_bytes(read_file(app / "JobTracking.bundle" / name, 4 * CHUNK_BYTES)),
                "Guest manifest resource hash differs")
    tracking = next(item for item in files if item["source"] == "job-tracking.mjs")
    require("f79ee0c7467b916fe822dce94df0201c6f905d7ca8a3dac3274673e5d34b3510" in tracking.get("previous_sha256", []),
            "Build 29 Guest tracking upgrade hash missing")
    patches = manifest.get("patches")
    require(isinstance(patches, list) and len(patches) == 1 and isinstance(patches[0], dict), "Guest index patch missing")
    patch = patches[0]
    require(patch.get("target") == "/usr/local/lib/dsh-plugins/dsh-host-bridge/index.js" and
            patch.get("original_sha256") == "b8e449621a37de7b74d85eb074861b711755bb2f122da8ee48e479c0eb4590f2" and
            patch.get("patched_sha256") == "f587c00109b3112cb4993ff57a3913a963a47dad2f77d60e4cfbe808db6d0d5e",
            "Guest index patch identity differs")
    entry = read_file(app / "JobTracking.bundle/job-tracking.mjs", 4 * CHUNK_BYTES)
    export = read_file(app / "JobTracking.bundle/workspace-export.mjs", 4 * CHUNK_BYTES)
    require(b"import { installWorkspaceExport } from './workspace-export.mjs';" in entry and
            b"installWorkspaceExport(ctx, defineTool," in entry and b"name: 'file_export_from_workspace'" in export,
            "Guest tool registration missing")
    return records


def inspect(app, source_root):
    require(app.is_dir() and not app.is_symlink(), "archive app directory missing or symlinked")
    info = plistlib.loads(read_file(app / "Info.plist", 2 * CHUNK_BYTES))
    require(isinstance(info, dict), "Info.plist must be a dictionary")
    expected = {"CFBundleIdentifier": APP_ID, "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "30",
                "CFBundleExecutable": "DSH", "MinimumOSVersion": "16.0", "CFBundlePackageType": "APPL"}
    require(all(info.get(key) == value for key, value in expected.items()), "App identity/version/minimum OS differs from Build 30 contract")
    require(not (app / "embedded.mobileprovision").exists() and not (app / "_CodeSignature").exists(),
            "archive app unexpectedly has provisioning or signature resources")
    macho = inspect_macho(read_file(app / "DSH", 128 * CHUNK_BYTES))
    root_hash, root_bytes = digest_file(app / "root.tar.gz")
    require(root_hash == ROOTFS_SHA256 and root_bytes == ROOTFS_BYTES, "bundled rootfs differs from the fixed image")
    require(read_file(app / "root.tar.gz.sha256", 4096).decode("ascii").strip() == ROOTFS_SHA256,
            "embedded rootfs SHA sidecar differs")
    resources = inspect_resources(app, source_root)
    onboarding = inspect_onboarding(app)
    return {"info": expected, "main_executable": macho,
            "rootfs": {"bytes": root_bytes, "sha256": root_hash, "decompressed_or_modified": False},
            "bundled_resource_count": len(resources), "bundle_resources": resources,
            "unsigned": {"main_code_signature_present": False, "profile_present": False, "signature_resources_present": False},
            "guest_registration_and_build29_upgrade_hash_present": True,
            "onboarding_canonical_upgrade": onboarding,
            "untracked_cloud_drafts_included": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    if args.json_output and (args.json_output.resolve() == args.app.resolve() or
                            args.app.resolve() in args.json_output.resolve().parents):
        parser.error("JSON receipt must be outside the read-only archive app")
    receipt = {"schema": 1, "accepted": False, "observed_utc": datetime.now(timezone.utc).isoformat(),
               "app": str(args.app), "source_root": str(args.source_root),
               "operations": {"archive_read_only": True, "signing": False, "installation": False},
               "limits": ["CI and exact checkout provenance are verified separately", "does not prove an iPad Files save"]}
    try:
        receipt.update(inspect(args.app, args.source_root))
        receipt["accepted"] = True
    except (Rejected, OSError, ValueError, TypeError, KeyError, struct.error) as error:
        receipt["error"] = {"type": type(error).__name__, "reason": str(error)}
    encoded = json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0 if receipt["accepted"] else 1


if __name__ == "__main__":
    sys.exit(main())
