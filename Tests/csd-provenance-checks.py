#!/usr/bin/env python3
"""Unit data-flow checks with synthetic files; no inspected ELF is executed."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("csd_provenance", ROOT / "scripts/write-csd-provenance.py")
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)


class ProvenanceChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pd-csd-provenance-unit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = self.root / "sdk"
        self.payload = self.root / "payload"
        self.theme = self.root / "Adwaita.theme"
        self.theme.mkdir()
        self.theme.joinpath("Adwaita").write_bytes(b"unstripped theme")
        self.lock = self.root / "lock.json"
        patch_file = self.root / "carry.patch"
        patch_file.write_bytes(b"synthetic unit patch, never applied")
        names = ["libobjc2", "libdispatch", "tools-make", "libs-base", "libs-corebase", "libs-gui", "libs-back"]
        components = [dict(name=name, url="https://example.invalid/" + name, revision="a" * 40,
                           configure_args=[], patches=[]) for name in names]
        components[-1]["patches"] = [dict(path="carry.patch", sha256=writer.check.digest(patch_file))]
        self.lock.write_text(json.dumps(dict(schema_version=1, kind="custom-toolchain-lock",
                                             install_domain="LOCAL", components=components)))
        pairs = [(writer.check.BACK, writer.check.STAGED_BACK),
                 ("Local/Library/Libraries/libgnustep-gui.so.0.32", writer.check.GUI),
                 ("Local/Library/Libraries/libgnustep-base.so.1.31", "runtime/lib/libgnustep-base.so.1.31"),
                 ("lib/libobjc.so.4.6", "runtime/lib/libobjc.so.4.6"),
                 ("lib/libdispatch.so", "runtime/lib/libdispatch.so")]
        elf_files = {}
        for original, final in pairs:
            source, staged = self.sdk / original, self.payload / final
            source.parent.mkdir(parents=True, exist_ok=True)
            staged.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(b"unstripped " + original.encode())
            staged.write_bytes(b"\x7fELFstripped " + b"\0".join(writer.check.KEYS))
            value = self.fake_identity(source)
            elf_files[original] = dict(sha256=value["sha256"], build_id=value["buildId"])
        for relative in ("runtime/System/Library/Themes/Adwaita.theme/Adwaita",
                         "app/PerformanceDashboard.app/PerformanceDashboard",
                         "app/PerformanceDashboard.app/Resources/libgsperf-agent.so",
                         "app/PerformanceDashboard.app/Resources/gsp-launch", "runtime/lib/gsp-launch"):
            file = self.payload / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"\x7fELFsynthetic unit payload")
        self.provenance = self.sdk / "gnustep-toolchain-provenance.json"
        self.provenance.write_text(json.dumps(dict(schema_version=1, kind="custom-gnustep-toolchain-provenance",
            official=False, install_domain="LOCAL", lock=dict(sha256=writer.check.digest(self.lock)),
            components=[dict(value, resolved_commit=value["revision"], applied_patches=value["patches"])
                        for value in components], elf_files=elf_files)))
        self.receipt = self.root / "theme-receipt.json"
        self.receipt.write_text(json.dumps(dict(schemaVersion=1,
            themeSourceRevision=json.loads((ROOT / "packaging/release-inputs.json").read_text())["adwaita"]["revision"],
            themeBinarySHA256=writer.check.digest(self.theme / "Adwaita"),
            toolchainLockSHA256=writer.check.digest(self.lock),
            toolchainProvenanceSHA256=writer.check.digest(self.provenance))))
        metadata = self.payload / "metadata"
        metadata.mkdir()
        for source, name in ((self.lock, "custom-toolchain-lock.json"),
                             (self.provenance, "custom-toolchain-provenance.json"),
                             (self.receipt, "adwaita-build-receipt.json")):
            (metadata / name).write_bytes(source.read_bytes())
        self.args = argparse.Namespace(lock=str(self.lock), sdk=str(self.sdk), payload=str(self.payload),
            backend=str((self.sdk / writer.check.BACK).parent), backend_sha256=writer.check.digest(self.sdk / writer.check.BACK),
            theme=str(self.theme), theme_sha256=writer.check.digest(self.theme / "Adwaita"),
            theme_receipt=str(self.receipt), commit="b" * 40, packager_commit="c" * 40,
            version="0.1.7-review", source_dirty="false", source_diff_sha256="d" * 64)
        self.addCleanup(patch.stopall)
        patch.object(writer, "identity", side_effect=self.fake_identity).start()
        patch.object(writer.check.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, "0000 T GSThemeInstallBackendDefaults\n", "")).start()

    def fake_identity(self, path):
        return dict(sha256=writer.check.digest(path),
                    buildId=hashlib.sha256(Path(path).name.split(".so", 1)[0].encode()).hexdigest()[:40])

    def test_fresh_record_has_custom_sources_and_no_managed_recipe(self):
        value = writer.make_record(self.args)
        self.assertEqual(set(value["inputs"]), {"customToolchain", "adwaita", "packager"})
        self.assertFalse(value["officialToolchain"])
        self.assertEqual(value["inputs"]["customToolchain"]["lock"], json.loads(self.lock.read_text()))
        self.assertEqual(value["inputs"]["customToolchain"]["sdkProvenance"], json.loads(self.provenance.read_text()))
        self.assertEqual(value["patchSHA256"][0]["component"], "libs-back")
        self.assertEqual(value["inputs"]["adwaita"]["buildReceipt"], json.loads(self.receipt.read_text()))
        self.assertNotIn("toolchainMetadata", value)
        self.assertNotIn("toolchainPayloadsVerified", value)
        self.assertNotIn("gnustep-toolchain", value["inputs"])
        self.assertNotEqual(value["payloadIdentityChecks"]["libs-back"]["source"]["sha256"],
                            value["payloadIdentityChecks"]["libs-back"]["payload"]["sha256"])

    def test_symlink_uses_resolved_sdk_elf_provenance_entry(self):
        original = self.sdk / "lib/libdispatch.so"
        actual = original.with_name("libdispatch.so.1.0")
        original.rename(actual)
        original.symlink_to(actual.name)
        value = json.loads(self.provenance.read_text())
        record = value["elf_files"].pop("lib/libdispatch.so")
        value["elf_files"]["lib/libdispatch.so.1.0"] = record
        self.provenance.write_text(json.dumps(value))
        receipt = json.loads(self.receipt.read_text())
        receipt["toolchainProvenanceSHA256"] = writer.check.digest(self.provenance)
        self.receipt.write_text(json.dumps(receipt))
        (self.payload / "metadata/custom-toolchain-provenance.json").write_bytes(self.provenance.read_bytes())
        (self.payload / "metadata/adwaita-build-receipt.json").write_bytes(self.receipt.read_bytes())
        result = writer.make_record(self.args)
        self.assertEqual(result["payloadIdentityChecks"]["libdispatch"]["resolvedSourcePath"], "lib/libdispatch.so.1.0")

    def test_missing_embedded_inputs_refuse(self):
        for path in (self.payload / "metadata").iterdir():
            saved = path.read_bytes()
            path.unlink()
            with self.subTest(path=path.name), self.assertRaises(OSError):
                writer.make_record(self.args)
            path.write_bytes(saved)

    def test_changed_embedded_lock_refuses(self):
        (self.payload / "metadata/custom-toolchain-lock.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "embedded input differs"):
            writer.make_record(self.args)

    def test_payload_build_id_mismatch_refuses(self):
        def changed(path):
            result = self.fake_identity(path)
            if Path(path) == self.payload / writer.check.STAGED_BACK:
                result["buildId"] = "0" * 40
            return result
        with patch.object(writer, "identity", side_effect=changed), self.assertRaisesRegex(ValueError, "build ID mismatch"):
            writer.make_record(self.args)

    def test_mutated_sdk_elf_refuses(self):
        (self.sdk / writer.check.BACK).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            writer.make_record(self.args)

    def test_missing_helper_payload_refuses(self):
        (self.payload / "runtime/lib/gsp-launch").unlink()
        with self.assertRaises(OSError):
            writer.make_record(self.args)

    def test_invalid_source_identity_refuses(self):
        self.args.commit = "floating-head"
        with self.assertRaisesRegex(ValueError, "source commit must be exact"):
            writer.make_record(self.args)

    def test_sdk_provenance_missing_refuses(self):
        self.provenance.unlink()
        with self.assertRaises(OSError):
            writer.make_record(self.args)


if __name__ == "__main__":
    unittest.main()
