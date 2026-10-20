#!/usr/bin/env python3
"""Check recipe integrity and safe license extraction without downloading."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare", ROOT / "scripts/prepare-windows-sources.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def tar_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for name, data in entries.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    return stream.getvalue()


class SourcePreparationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.upstream = tar_bytes({"example/LICENSE": b"Example license", "../../COPYING": b"Another notice"})

    def package(self, checksum=None, include_input=True):
        checksum = checksum or hashlib.sha256(self.upstream).hexdigest()
        metadata = f"pkgbase = example\n source = example.tar.gz\n sha256sums = {checksum}\n".encode()
        entries = {"example/.SRCINFO": metadata, "example/PKGBUILD": b"not executed"}
        if include_input:
            entries["example/example.tar.gz"] = self.upstream
        path = self.root / "source.tar.gz"
        path.write_bytes(tar_bytes(entries))
        return path

    def test_valid_inputs_and_license_texts(self):
        verified, licenses = module.inspect(self.package(), self.root / "licenses")
        self.assertEqual(verified, ["example.tar.gz"])
        self.assertEqual(len(licenses), 2)
        self.assertTrue(all((self.root / "licenses" / item["file"]).is_file() for item in licenses))
        self.assertFalse((self.root.parent / "COPYING").exists())
        self.assertTrue(all(len(item["sha256"]) == 64 for item in licenses))

    def test_changed_recipe_input_rejected(self):
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            module.inspect(self.package("0" * 64), self.root / "licenses")

    def test_missing_recipe_input_rejected(self):
        with self.assertRaisesRegex(ValueError, "Missing recipe input"):
            module.inspect(self.package(include_input=False), self.root / "licenses")

    def test_recipe_required(self):
        path = self.root / "incomplete.tar.gz"
        path.write_bytes(tar_bytes({"LICENSE": b"A notice without source"}))
        with self.assertRaisesRegex(ValueError, "Missing recipe metadata"):
            module.inspect(path, self.root / "licenses")


if __name__ == "__main__":
    unittest.main()
