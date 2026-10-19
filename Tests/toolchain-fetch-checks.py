#!/usr/bin/env python3
"""Check locked-cache failure behavior without executing a bootstrap."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fetcher", ROOT / "scripts/fetch-toolchain.py")
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class FetchChecks(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.cache = self.root / "cache"
        self.payload = "toolchain.zip"
        (self.remote / self.payload).write_bytes(b"fixture payload")
        (self.remote / "gnustep-bootstrap.ps1").write_bytes(b"never execute this fixture")
        (self.remote / "release-manifest.json.sig").write_bytes(b"signature fixture")
        self.manifest = {"releases": [{"artifacts": [{"filename": self.payload,
                          "sha256": fetcher.sha256(self.remote / self.payload)}]}]}
        self.write_lock()
        patch = mock.patch.object(fetcher, "ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)
        # Cryptographic verification is exercised against published signed
        # metadata separately. These tests check ordering and fail-closed logic.
        self.verifier = mock.patch.object(fetcher.subprocess, "run").start()
        self.addCleanup(mock.patch.stopall)

    def write_lock(self):
        (self.remote / "release-manifest.json").write_text(json.dumps(self.manifest))
        lock = {"baseUrl": self.remote.as_uri(), "files": {
            name: fetcher.sha256(self.remote / name) for name in
            ("gnustep-bootstrap.ps1", "release-manifest.json", "release-manifest.json.sig", self.payload)}}
        (self.root / "packaging").mkdir(exist_ok=True)
        (self.root / "packaging/release-inputs.json").write_text(json.dumps({"gnustep-toolchain-windows": lock}))

    def fetch(self, metadata_only=False):
        return fetcher.fetch(self.cache, "windows", metadata_only)

    def test_valid_cache_is_reusable(self):
        self.fetch()
        self.fetch()
        self.assertEqual(self.verifier.call_count, 2)
        self.assertEqual((self.cache / self.payload).read_bytes(), b"fixture payload")

    def test_changed_upstream_bytes_are_refused(self):
        (self.remote / "gnustep-bootstrap.ps1").write_bytes(b"replaced bootstrap")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            self.fetch()
        self.assertFalse((self.cache / "gnustep-bootstrap.ps1").exists())
        self.assertFalse(list(self.cache.glob("*.partial")))
        self.verifier.assert_not_called()

    def test_corrupted_cache_is_not_silently_replaced(self):
        self.fetch()
        self.verifier.reset_mock()
        (self.cache / self.payload).write_bytes(b"corrupted cache")
        with self.assertRaisesRegex(ValueError, "cached SHA256 mismatch"):
            self.fetch()
        self.assertEqual((self.cache / self.payload).read_bytes(), b"corrupted cache")
        self.verifier.assert_not_called()

    def test_signature_failure_is_fatal(self):
        self.verifier.side_effect = subprocess.CalledProcessError(1, ["openssl"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.fetch()

    def test_metadata_only_verifies_signature_without_payload_download(self):
        (self.remote / self.payload).unlink()
        self.fetch(metadata_only=True)
        self.verifier.assert_called_once()
        self.assertFalse((self.cache / self.payload).exists())

    def test_signed_manifest_must_agree_with_payload_lock(self):
        self.manifest["releases"][0]["artifacts"][0]["sha256"] = "0" * 64
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "signed manifest disagrees"):
            self.fetch(metadata_only=True)


if __name__ == "__main__":
    unittest.main()
