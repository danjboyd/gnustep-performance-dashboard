#!/usr/bin/env python3
"""Release-assembly failure cases use disposable synthetic artifact bytes."""

import hashlib
import base64
import os
import subprocess
import sys
from unittest.mock import patch
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("assembly", ROOT / "scripts/assemble-release.py")
assembly = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assembly)
VERSION = "0.1.1-rc1"
COMMIT = "a" * 40


def write_json(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


def source_archive(path, commit=COMMIT):
    inner = io.BytesIO()
    with tarfile.open(fileobj=inner, mode="w", format=tarfile.PAX_FORMAT,
                      pax_headers={"comment": commit}) as source:
        member = tarfile.TarInfo("PerformanceDashboard/LICENSE")
        member.size = 7
        source.addfile(member, io.BytesIO(b"fixture"))
    data = inner.getvalue()
    with tarfile.open(path, "w:gz") as archive:
        member = tarfile.TarInfo("sources/PerformanceDashboard.tar")
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))


class AssemblyChecks(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.linux = self.root / "linux"
        self.windows = self.root / "windows"
        self.output = self.root / "release"
        self.feeds = {}
        self.provenance = {}
        self.build_fixture(self.linux, "appimage")
        self.build_fixture(self.windows, "msi")

    def build_fixture(self, directory, backend):
        directory.mkdir()
        platform = assembly.PLATFORMS[backend]
        suffix = "x86_64.AppImage" if backend == "appimage" else "win64.msi"
        binary = f"PerformanceDashboard-{VERSION}-{suffix}"

        def payload(name):
            data = ("Synthetic artifact: " + name).encode()
            (directory / name).write_bytes(data)
            return {"name": name, "sha256": hashlib.sha256(data).hexdigest(),
                    "sizeBytes": len(data),
                    "url": f"{assembly.REPOSITORY}/releases/download/v{VERSION}/{name}"}

        asset = payload(binary)
        asset.update(backend=backend, platform=platform + "-x64")
        if backend == "appimage":
            asset["zsync"] = payload(binary + ".zsync")
            provenance = {"version": VERSION, "commit": COMMIT, "sourceDirty": False}
            source_name = f"PerformanceDashboard-{VERSION}-sources.tar.gz"
        else:
            portable = payload(f"PerformanceDashboard-{VERSION}-win64-portable.zip")
            provenance = {"package": {"version": VERSION},
                          "source": {"commit": COMMIT, "dirty": False},
                          "artifact": asset, "relatedArtifacts": [portable]}
            source_name = f"PerformanceDashboard-{VERSION}-windows-sources.tar.gz"
        stem = binary.rsplit(".", 1)[0]
        self.provenance[backend] = directory / (stem + ".provenance.json")
        write_json(self.provenance[backend], provenance)
        source_archive(directory / source_name)
        feed = {"formatVersion": 1, "provider": "github-release-feed", "channel": "prerelease",
                "feedUrl": f"{assembly.PAGES}/updates/{platform}/prerelease.json",
                "package": {"id": assembly.PACKAGE_ID, "version": VERSION},
                "releases": [{"version": VERSION, "tag": "v" + VERSION, "assets": [asset]}]}
        self.feeds[backend] = directory / (stem + ".update-feed.json")
        write_json(self.feeds[backend], feed)

    def assemble(self):
        assembly.assemble([self.linux, self.windows], self.output, VERSION, COMMIT, ["appimage", "msi"])

    def refused(self, message):
        with self.assertRaisesRegex(ValueError, message):
            self.assemble()
        self.assertFalse(self.output.exists(), "Failed validation must not leave a releasable directory")

    def sign_linux(self):
        private = self.root / "throwaway.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private)],
                       check=True, capture_output=True)
        os.chmod(private, 0o600)
        seed = subprocess.check_output(["openssl", "pkey", "-in", str(private), "-outform", "DER"])[-32:]
        public = subprocess.check_output(["openssl", "pkey", "-in", str(private), "-pubout", "-outform", "DER"])[-32:]
        env = {"UPDATE_ED_PRIVATE_KEY": base64.b64encode(seed).decode(),
               "UPDATE_ED_PUBLIC_KEY": base64.b64encode(public).decode()}
        subprocess.run([sys.executable, str(ROOT/"scripts/sign-update-feed.py"),
                        str(self.feeds["appimage"]), str(self.linux)],
                       env=dict(os.environ, **env), check=True, capture_output=True)
        p = assembly.load(self.provenance["appimage"])
        p["updatesPublicEDKey"] = env["UPDATE_ED_PUBLIC_KEY"]
        p["updatesPackageIdentifier"] = assembly.PACKAGE_ID
        write_json(self.provenance["appimage"], p)
        return env

    def test_signed_distribution_feed_and_checksums(self):
        env = self.sign_linux()
        with patch.dict(os.environ, env):
            assembly.assemble([self.linux], self.output, VERSION, COMMIT, ["appimage"], True)
        final = assembly.load(self.output/"site/updates/linux/prerelease.json")
        self.assertIn("edSignature", final["releases"][0]["assets"][0])
        self.assertIn("versionSignature", final["releases"][0]["assets"][0])
        self.assertEqual(final, assembly.load(self.feeds["appimage"]))
        self.assertIn(assembly.digest(self.output/self.feeds["appimage"].name),
                      (self.output/"SHA256SUMS").read_text())

    def test_required_signatures_reject_missing_bad_and_mismatched_build_key(self):
        env = self.sign_linux()
        good = assembly.load(self.feeds["appimage"])
        with patch.dict(os.environ, env):
            for signature in [None, base64.b64encode(bytes(64)).decode()]:
                feed = json.loads(json.dumps(good))
                asset = feed["releases"][0]["assets"][0]
                if signature is None: asset.pop("edSignature")
                else: asset["edSignature"] = signature
                write_json(self.feeds["appimage"], feed)
                with self.assertRaises(ValueError):
                    assembly.assemble([self.linux], self.output, VERSION, COMMIT, ["appimage"], True)
                self.assertFalse(self.output.exists())
            write_json(self.feeds["appimage"], good)
            p = assembly.load(self.provenance["appimage"])
            p["updatesPublicEDKey"] = base64.b64encode(bytes(32)).decode()
            write_json(self.provenance["appimage"], p)
            with self.assertRaisesRegex(ValueError, "Packaged public key"):
                assembly.assemble([self.linux], self.output, VERSION, COMMIT, ["appimage"], True)
            self.assertFalse(self.output.exists())

    def test_assembly_refuses_missing_or_invalid_bound_version_signature(self):
        env = self.sign_linux()
        good = assembly.load(self.feeds["appimage"])
        with patch.dict(os.environ, env):
            for signature in [None, base64.b64encode(bytes(64)).decode()]:
                feed = json.loads(json.dumps(good))
                asset = feed["releases"][0]["assets"][0]
                if signature is None: asset.pop("versionSignature")
                else: asset["versionSignature"] = signature
                write_json(self.feeds["appimage"], feed)
                with self.assertRaises(ValueError):
                    assembly.assemble([self.linux], self.output, VERSION, COMMIT, ["appimage"], True)
                self.assertFalse(self.output.exists())

    def test_package_id_matches_manifest_and_packaged_client_configuration(self):
        manifest = assembly.load(ROOT/"packaging/package.manifest.json")
        self.assertEqual(manifest["package"]["id"], assembly.PACKAGE_ID)
        env = self.sign_linux()
        provenance = assembly.load(self.provenance["appimage"])
        provenance["updatesPackageIdentifier"] = assembly.PACKAGE_ID+".other"
        write_json(self.provenance["appimage"], provenance)
        with patch.dict(os.environ, env), self.assertRaisesRegex(ValueError, "package id"):
            assembly.assemble([self.linux], self.output, VERSION, COMMIT, ["appimage"], True)
        self.assertFalse(self.output.exists())

    def test_combined_release_and_all_checksums(self):
        self.assemble()
        receipt = assembly.load(self.output / "assembly.json")
        self.assertEqual(receipt["backends"], ["appimage", "msi"])
        self.assertEqual(len(receipt["validatedPayloads"]), 4)
        for line in (self.output / "SHA256SUMS").read_text().splitlines():
            expected, name = line.split("  ", 1)
            self.assertEqual(assembly.digest(self.output / name), expected)
        self.assertTrue((self.output / "site/updates/windows/prerelease.json").is_file())
        self.assertFalse((self.output / "site/updates/windows/stable.json").exists())

    def test_changed_binary_is_refused(self):
        next(self.windows.glob("*.msi")).write_bytes(b"replaced payload")
        self.refused("Payload digest mismatch")

    def test_wrong_channel_is_refused(self):
        feed = assembly.load(self.feeds["msi"])
        feed["channel"] = "stable"
        write_json(self.feeds["msi"], feed)
        self.refused("Wrong update channel")

    def test_dirty_windows_build_is_refused(self):
        data = assembly.load(self.provenance["msi"])
        data["source"]["dirty"] = True
        write_json(self.provenance["msi"], data)
        self.refused("Windows provenance must name the clean release commit")

    def test_mixed_source_commits_are_refused(self):
        data = assembly.load(self.provenance["appimage"])
        data["commit"] = "b" * 40
        write_json(self.provenance["appimage"], data)
        self.refused("Linux provenance must name the clean release commit")

    def test_wrong_source_archive_is_refused(self):
        source_archive(next(self.windows.glob("*sources.tar.gz")), "b" * 40)
        self.refused("Corresponding sources name another commit")

    def test_missing_windows_sources_are_refused(self):
        next(self.windows.glob("*sources.tar.gz")).unlink()
        self.refused("Missing corresponding-source archive")

    def test_duplicate_filename_with_different_bytes_is_refused(self):
        (self.windows / "build.metadata.json").write_text("one")
        (self.linux / "build.metadata.json").write_text("two")
        self.refused("Conflicting artifact name")

    def test_wrong_download_release_is_refused(self):
        feed = assembly.load(self.feeds["msi"])
        feed["releases"][0]["assets"][0]["url"] = "https://example.invalid/old.msi"
        write_json(self.feeds["msi"], feed)
        self.refused("Wrong release download URL")

    def test_unreferenced_stale_binary_is_refused(self):
        (self.windows / "old.msi").write_bytes(b"stale")
        self.refused("Unreferenced binary artifact")

    def test_missing_portable_zip_is_refused(self):
        next(self.windows.glob("*-portable.zip")).unlink()
        self.refused("Missing payload")

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_text("existing")
        with self.assertRaisesRegex(ValueError, "Output already exists"):
            self.assemble()
        self.assertEqual(marker.read_text(), "existing")


if __name__ == "__main__":
    unittest.main()
