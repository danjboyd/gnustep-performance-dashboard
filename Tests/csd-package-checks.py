#!/usr/bin/env python3
"""Static unit fixtures only; no custom SDK or inspected binary is executed."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("csd_check", ROOT / "scripts/check-csd-package.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class CSDChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pd-csd-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = self.root / "stage"
        self.backend = self.stage / check.STAGED_BACK
        self.gui = self.stage / check.GUI
        self.backend.parent.mkdir(parents=True)
        self.gui.parent.mkdir(parents=True)
        # Synthetic fixtures, deliberately not executable ELF payloads.
        self.backend.write_bytes(b"\x7fELF" + b"\0".join(check.KEYS))
        self.gui.write_bytes(b"\x7fELFfixture")

    def test_required_backend_keys_fail_closed(self):
        for key in check.KEYS:
            with self.subTest(key=key):
                self.backend.write_bytes(b"\x7fELF" + key)
                with self.assertRaisesRegex(ValueError, "backend lacks"):
                    check.check_staged(self.stage)

    def test_exact_defined_gui_export_required(self):
        for output in ("", "                 U GSThemeInstallBackendDefaults\n",
                       "00000000 T GSThemeInstallBackendDefaultsSuffix\n"):
            with self.subTest(output=output), patch.object(check.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0, output, "")):
                with self.assertRaisesRegex(ValueError, "dynamic export"):
                    check.check_staged(self.stage)
        with patch.object(check.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "00000000 T GSThemeInstallBackendDefaults\n", "")):
            self.assertEqual(check.check_staged(self.stage)["backendSHA256"], check.digest(self.backend))

    def test_nm_failure_is_not_success(self):
        with patch.object(check.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "nm")):
            with self.assertRaises(subprocess.CalledProcessError):
                check.check_staged(self.stage)

    def fixture_inputs(self):
        sdk = self.root / "sdk"
        backend = sdk / check.BACK
        backend.parent.mkdir(parents=True)
        backend.write_bytes(b"test backend identity")
        theme = self.root / "Adwaita.theme"
        theme.mkdir()
        (theme / "Adwaita").write_bytes(b"test theme identity")
        lock_path = self.root / "lock.json"
        component = dict(name="libs-back", url="https://example.invalid/back.git",
                         revision="a" * 40, configure_args=[], patches=[])
        lock_path.write_text(json.dumps(dict(install_domain="LOCAL", components=[component])))
        provenance = dict(schema_version=1, kind="custom-gnustep-toolchain-provenance",
                         official=False, install_domain="LOCAL", lock=dict(sha256=check.digest(lock_path)),
                         components=[dict(**component, resolved_commit="a" * 40, applied_patches=[])],
                         elf_files={check.BACK: dict(sha256=check.digest(backend))})
        provenance_path = sdk / "gnustep-toolchain-provenance.json"
        provenance_path.write_text(json.dumps(provenance))
        receipt_path = self.root / "theme-build.json"
        theme_revision = json.loads((ROOT / "packaging/release-inputs.json").read_text())["adwaita"]["revision"]
        receipt_path.write_text(json.dumps(dict(schemaVersion=1,
            toolchainLockSHA256=check.digest(lock_path), toolchainProvenanceSHA256=check.digest(provenance_path),
            themeBinarySHA256=check.digest(theme / "Adwaita"), themeSourceRevision=theme_revision)))
        return argparse.Namespace(lock=str(lock_path), sdk=str(sdk), backend=str(backend.parent),
                                  backend_sha256=check.digest(backend), theme=str(theme),
                                  theme_sha256=check.digest(theme / "Adwaita"), theme_receipt=str(receipt_path))

    def test_matching_synthetic_input_identities_only(self):
        args = self.fixture_inputs()
        self.assertEqual(check.check_inputs(args)["backendSHA256"], args.backend_sha256)

    def test_mismatched_sha_sdk_theme_receipt_rejected(self):
        for field in ("backend_sha256", "theme_sha256"):
            args = self.fixture_inputs() if not (self.root / "sdk").exists() else self.args
            self.args = args
            modified = copy.copy(args)
            setattr(modified, field, "0" * 64)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                check.check_inputs(modified)
        receipt = Path(args.theme_receipt)
        value = json.loads(receipt.read_text())
        value["toolchainLockSHA256"] = "0" * 64
        receipt.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "theme build receipt"):
            check.check_inputs(args)

    def test_non_sdk_backend_rejected(self):
        args = self.fixture_inputs()
        outside = self.root / "old-backend"
        outside.mkdir()
        (outside / "libgnustep-back-032").write_bytes(b"test backend identity")
        args.backend = str(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            check.check_inputs(args)

    def test_missing_explicit_inputs_fail_before_stage_mutation(self):
        marker = self.stage / "keep-me"
        marker.write_text("unchanged")
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("PD_CSD_") and key not in ("LIBS_BACK_BUNDLE", "ADWAITA_THEME")}
        env.update(PD_CSD_TOOLCHAIN_LOCK="not-used-yet", GNUSTEP_CLI_ROOT=str(self.root / "sdk"))
        result = subprocess.run(["bash", str(ROOT / "scripts/package-stage.sh"), str(self.stage)],
                                env=env, text=True, capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("custom CSD requires the SDK backend bundle", result.stderr)
        self.assertEqual(marker.read_text(), "unchanged")

    def test_custom_sdk_cannot_silently_take_legacy_mode(self):
        sdk = self.root / "sdk"
        sdk.mkdir()
        (sdk / "gnustep-toolchain-provenance.json").write_text("{}")
        env = {key: value for key, value in os.environ.items() if not key.startswith("PD_CSD_")}
        env["GNUSTEP_CLI_ROOT"] = str(sdk)
        result = subprocess.run(["bash", str(ROOT / "scripts/package-stage.sh"), str(self.stage)],
                                env=env, text=True, capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires explicit PD_CSD_TOOLCHAIN_LOCK", result.stderr)


if __name__ == "__main__":
    unittest.main()
