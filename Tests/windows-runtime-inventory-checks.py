#!/usr/bin/env python3
"""Exercise runtime ownership, tamper rejection and license completeness."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("inventory", ROOT / "scripts/windows-runtime-inventory.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RuntimeInventoryChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.stage, self.tools, self.project = root / "stage", root / "tools", root / "project"
        for path in (self.stage / "runtime/bin", self.tools / "clang64/bin",
                     self.tools / "clang64/share/licenses/example", self.project):
            path.mkdir(parents=True)
        self.binary = self.stage / "runtime/bin/example.dll"
        self.binary.write_bytes(b"exact dependency bytes")
        (self.tools / "clang64/bin/example.dll").write_bytes(self.binary.read_bytes())
        (self.tools / "clang64/share/licenses/example/LICENSE").write_text("Example license text")
        self.database = self.tools / "var/lib/pacman/local/example-1.0-1"
        self.database.mkdir(parents=True)
        (self.database / "desc").write_text("%NAME%\nexample\n\n%VERSION%\n1.0-1\n\n%LICENSE%\nMIT\n")
        (self.database / "files").write_text(
            "%FILES%\nclang64/bin/example.dll\nclang64/share/licenses/example/LICENSE\n")

    def run_inventory(self):
        return module.inventory(self.stage, self.tools, self.project)

    def test_maps_bytes_and_copies_package_license(self):
        result = self.run_inventory()
        self.assertEqual(result["files"][0]["owners"], ["example"])
        self.assertEqual(result["packages"][0]["version"], "1.0-1")
        license_path = self.stage / result["packages"][0]["licenseFiles"][0]["path"]
        self.assertEqual(license_path.read_text(), "Example license text")
        self.assertEqual(result["missingLicenseTexts"], [])

    def test_modified_staged_dependency_rejected(self):
        self.binary.write_bytes(b"modified dependency")
        with self.assertRaisesRegex(ValueError, "No byte-identical"):
            self.run_inventory()

    def test_unowned_dependency_rejected(self):
        (self.stage / "runtime/bin/unowned.dll").write_bytes(b"unknown")
        with self.assertRaisesRegex(ValueError, "unowned.dll"):
            self.run_inventory()

    def test_missing_license_reported(self):
        (self.tools / "clang64/share/licenses/example/LICENSE").unlink()
        self.assertEqual(self.run_inventory()["missingLicenseTexts"], ["example"])

    def test_project_binary_requires_matching_bytes(self):
        source = self.project / "Tools/gstrace/obj/gstrace.exe"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"our recorder")
        target = self.stage / "runtime/bin/gstrace.exe"
        target.write_bytes(source.read_bytes())
        result = self.run_inventory()
        self.assertEqual(next(f for f in result["files"] if f["path"].endswith("gstrace.exe"))["owner"],
                         "Performance Dashboard")
        target.write_bytes(b"different recorder")
        with self.assertRaisesRegex(ValueError, "gstrace.exe"):
            self.run_inventory()

    def test_source_license_fallback_and_tamper_rejection(self):
        (self.tools / "clang64/share/licenses/example/LICENSE").unlink()
        cache = self.project / "sources"
        text = cache / "licenses/example/0-COPYING"
        text.parent.mkdir(parents=True)
        text.write_text("Preserved upstream text")
        archive = cache / "example.src.tar.zst"
        archive.write_bytes(b"verified source archive")
        receipt = {"filename": archive.name, "sha256": module.digest(archive),
                   "binaryPackages": ["example"], "base": "example",
                   "extractedLicenses": [{"file": text.name, "sha256": module.digest(text),
                                           "archiveMember": "example.tar.gz:example/COPYING"}]}
        (cache / (archive.name + ".json")).write_text(json.dumps(receipt))
        result = module.inventory(self.stage, self.tools, self.project, cache)
        self.assertEqual(result["missingLicenseTexts"], [])
        self.assertEqual(result["packages"][0]["licenseFiles"][0]["sourceArchive"], archive.name)
        text.write_text("Changed license")
        with self.assertRaisesRegex(ValueError, "license changed"):
            module.inventory(self.stage, self.tools, self.project, cache)
        archive.write_bytes(b"Changed source")
        with self.assertRaisesRegex(ValueError, "archive changed"):
            module.inventory(self.stage, self.tools, self.project, cache)


if __name__ == "__main__":
    unittest.main()
