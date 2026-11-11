#!/usr/bin/env python3
"""Mutation checks for combined review identity and exact direct-library gates."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("csd_review", ROOT / "scripts/check-csd-package.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class ReviewChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pd-review-input-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.inputs = self.root / "linux"
        shutil.copytree(ROOT / "packaging/linux", self.inputs)
        self.manifest = self.inputs / "v017-review-inputs.json"

    def update_manifest(self, change):
        value = json.loads(self.manifest.read_text())
        change(value)
        self.manifest.write_text(json.dumps(value))

    def test_reviewed_combination_and_order(self):
        result = check.check_review_inputs(self.manifest)
        self.assertEqual(result["sdkPatchCount"], 16)
        self.assertEqual(result["applicationPatchCount"], 1)
        self.update_manifest(lambda value: value["sdkPatchOrder"].reverse())
        with self.assertRaisesRegex(ValueError, "order/count"):
            check.check_review_inputs(self.manifest)

    def test_changed_sdk_patch_bytes_refused(self):
        value = json.loads(self.manifest.read_text())
        target = self.inputs / value["sdkPatchOrder"][-1]["path"]
        target.write_bytes(target.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            check.check_review_inputs(self.manifest)

    def test_application_patch_cannot_be_asserted_against_other_source(self):
        self.update_manifest(lambda value: value["applicationPatches"][0]["appliedSource"].update(sha256="0" * 64))
        with self.assertRaisesRegex(ValueError, "applied application source SHA-256 mismatch"):
            check.check_review_inputs(self.manifest)

    def test_forced_negative_xfixes_refused_even_with_updated_lock_digest(self):
        lock = self.inputs / "v017-custom-toolchain.lock.proposed.json"
        value = json.loads(lock.read_text())
        value["components"][-1]["configure_args"].append("ac_cv_lib_Xfixes_XFixesSelectSelectionInput=no")
        lock.write_text(json.dumps(value))
        self.update_manifest(lambda value: value["toolchainLock"].update(sha256=check.digest(lock)))
        with self.assertRaisesRegex(ValueError, "forces an XFixes"):
            check.check_review_inputs(self.manifest)

    def test_exact_direct_dependencies_reject_extra_and_missing(self):
        policy = self.inputs / "v017-backend-needed.json"
        expected = json.loads(policy.read_text())["expectedNeeded"]
        backend = self.root / "fixture"
        backend.write_bytes(b"synthetic ELF identity only")
        log = self.root / "link.log"
        log.write_text("synthetic executed-command fixture\n")
        for libraries, accepted in ((expected, True), (expected + ["libXft.so.2"], False),
                                    ([name for name in expected if name != "libXfixes.so.3"], False)):
            output = "\n".join(" (NEEDED) Shared library: [" + name + "]" for name in libraries)
            with self.subTest(libraries=libraries), patch.object(check.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0, output, "")):
                if accepted:
                    self.assertEqual(check.check_backend_needed(backend, policy, log)["needed"], sorted(expected))
                else:
                    with self.assertRaisesRegex(ValueError, "DT_NEEDED differs"):
                        check.check_backend_needed(backend, policy, log)

    def test_combined_packaging_route_cannot_omit_link_log(self):
        fixtures_spec = importlib.util.spec_from_file_location("csd_fixtures", ROOT / "Tests/csd-package-checks.py")
        fixtures = importlib.util.module_from_spec(fixtures_spec)
        fixtures_spec.loader.exec_module(fixtures)
        fixture = fixtures.CSDChecks("test_matching_synthetic_input_identities_only")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args = fixture.fixture_inputs()
        lock = Path(args.lock)
        value = json.loads(lock.read_text())
        value["pd_review"] = {"review_inputs": "review.json"}
        lock.write_text(json.dumps(value))
        provenance = Path(args.sdk) / "gnustep-toolchain-provenance.json"
        value = json.loads(provenance.read_text())
        value["lock"]["sha256"] = check.digest(lock)
        provenance.write_text(json.dumps(value))
        (lock.parent / "review.json").write_text(json.dumps({"backendNeededPolicy": {"path": "policy.json"}}))
        (lock.parent / "policy.json").write_text("{}")
        with patch.object(check, "check_review_inputs", return_value={"lockSHA256": check.digest(lock)}), \
                patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "require PD_CSD_BACKEND_LINK_LOG"):
                check.check_inputs(args)

    def test_explicit_production_manifest_refuses_a_different_lock(self):
        fixtures_spec = importlib.util.spec_from_file_location("csd_other_fixture", ROOT / "Tests/csd-package-checks.py")
        fixtures = importlib.util.module_from_spec(fixtures_spec)
        fixtures_spec.loader.exec_module(fixtures)
        fixture = fixtures.CSDChecks("test_matching_synthetic_input_identities_only")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args = fixture.fixture_inputs()
        args.review_inputs = str(ROOT / "packaging/linux/v017-review-inputs.json")
        with self.assertRaisesRegex(ValueError, "review manifest names another lock"):
            check.check_inputs(args)


if __name__ == "__main__":
    unittest.main()
