#!/usr/bin/env python3
"""Throwaway-key signing/verification and real updater-helper local-file checks.

No product key, repo secret, network, real AppImage or installed app is used.
Set PD_TEST_UPDATE_HELPER to an owned test build of the vendored helper to
exercise its independent Monocypher verification and local prepare/apply path.
"""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/sign-update-feed.py"


class SigningChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pd-signing-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        key = self.work / "throwaway.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(key)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.chmod(key, 0o600)
        seed = subprocess.check_output(["openssl", "pkey", "-in", str(key), "-outform", "DER"])[-32:]
        public = subprocess.check_output(["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"])[-32:]
        self.env = dict(os.environ)
        # Explicitly replace any inherited signing inputs; only throwaway bytes run.
        self.env.update(UPDATE_ED_PRIVATE_KEY=base64.b64encode(seed).decode(),
                        UPDATE_ED_PUBLIC_KEY=base64.b64encode(public).decode(), HOME=str(self.work))
        self.payload = self.work / "PerformanceDashboard-0.1.5-test.AppImage"
        self.payload.write_bytes(b"#!/bin/sh\nprintf 'local fixture 0.1.5\\n'\n")
        self.feed = self.work / "fixture.update-feed.json"
        asset = {"backend": "appimage", "platform": "linux-x64", "name": self.payload.name,
                 "url": self.payload.as_uri(), "sizeBytes": self.payload.stat().st_size,
                 "sha256": hashlib.sha256(self.payload.read_bytes()).hexdigest()}
        self.unsigned = {"formatVersion": 1, "channel": "stable",
                         "package": {"id": "io.github.danjboyd.SigningFixture"},
                         "releases": [{"version": "0.1.5", "assets": [asset]}]}
        self.write(self.unsigned)

    def write(self, data):
        self.feed.write_text(json.dumps(data))

    def run_signer(self, *args, ok=True, env=None):
        p = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], env=env or self.env,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode == 0, ok, p.stderr)
        return p

    def sign(self):
        self.run_signer(self.feed, self.work)
        return json.loads(self.feed.read_text())

    def test_valid_bad_and_missing_signature(self):
        good = self.sign()
        self.run_signer("--verify", self.feed, self.work)
        bad = copy.deepcopy(good)
        sig = bytearray(base64.b64decode(bad["releases"][0]["assets"][0]["edSignature"]))
        sig[0] ^= 1
        bad["releases"][0]["assets"][0]["edSignature"] = base64.b64encode(sig).decode()
        self.write(bad)
        self.run_signer("--verify", self.feed, self.work, ok=False)
        self.write(self.unsigned)
        self.run_signer("--verify", self.feed, self.work, ok=False)

    def test_packager_published_canonical_vector(self):
        # Public test key/vector from v0.1.10 docs/update-feed-contract.md.
        # This is never a product signing key and is refused by its manifest validator.
        self.payload.write_bytes(b"not really an installer")
        feed = copy.deepcopy(self.unsigned)
        feed["package"]["id"] = "com.example.MyGNUstepApp"
        feed["releases"][0]["version"] = "1.2.3"
        asset = feed["releases"][0]["assets"][0]
        asset.update(backend="msi", platform="windows-x64", sizeBytes=23,
                     sha256="110499c3d4d34a94a1ea70ae7e7353d32708e043bc0ccee13ec9fbdb7a9d20b1")
        self.write(feed)
        env = dict(self.env,
            UPDATE_ED_PRIVATE_KEY=base64.b64encode(b"gnustep-packager test key, never").decode(),
            UPDATE_ED_PUBLIC_KEY="Ll6BcPIwCiJWeu8fUhAG52rU62luKpZdTNsdJBfgxIs=")
        self.run_signer(self.feed, self.work, env=env)
        actual = json.loads(self.feed.read_text())["releases"][0]["assets"][0]
        self.assertEqual(actual["edSignature"],
            "OontQOUseqhwI8bs9WutMZpDP8CsAJ7VAmIO0CC3B40C29NAXAk7mHaLJVtbDOQxK+tUxuneXomb1b8VAoQ7Bw==")
        self.assertEqual(actual["versionSignature"],
            "OznddanxdN2fuBl7/hJlwqj+rFthQ+ItcaDcH25RKtjymCuDudMpn+23Ynocc+6d8im05LYjMhCWnaGyK39+BA==")
        self.run_signer("--verify", self.feed, self.work, env=env)

    def test_missing_channel_or_platform_fails_without_writing_feed(self):
        for field in ("channel", "platform"):
            feed = copy.deepcopy(self.unsigned)
            if field == "channel": del feed["channel"]
            else: del feed["releases"][0]["assets"][0]["platform"]
            self.write(feed)
            before = self.feed.read_bytes()
            self.run_signer(self.feed, self.work, ok=False)
            self.assertEqual(self.feed.read_bytes(), before)

    def test_bound_identity_changes_and_missing_version_signature_are_refused(self):
        good = self.sign()
        for field in ("package", "version", "channel", "platform", "missing", "bad"):
            with self.subTest(field=field):
                feed = copy.deepcopy(good)
                asset = feed["releases"][0]["assets"][0]
                if field == "package": feed["package"]["id"] += ".other"
                elif field == "version": feed["releases"][0]["version"] = "0.1.6"
                elif field == "channel": feed["channel"] = "prerelease"
                elif field == "platform": asset["platform"] = "linux-arm64"
                elif field == "missing": del asset["versionSignature"]
                else: asset["versionSignature"] = base64.b64encode(bytes(64)).decode()
                self.write(feed)
                self.run_signer("--verify", self.feed, self.work, ok=False)

    def test_wrong_key_and_changed_payload_fail_without_partial_feed(self):
        before = self.feed.read_bytes()
        env = dict(self.env, UPDATE_ED_PUBLIC_KEY=base64.b64encode(bytes(32)).decode())
        self.run_signer(self.feed, self.work, env=env, ok=False)
        self.assertEqual(self.feed.read_bytes(), before)
        self.payload.write_bytes(b"changed")
        self.run_signer(self.feed, self.work, ok=False)
        self.assertEqual(self.feed.read_bytes(), before)

    def test_extended_seed_matches_public_and_late_payload_failure_is_atomic(self):
        private = base64.b64decode(self.env["UPDATE_ED_PRIVATE_KEY"])
        public = base64.b64decode(self.env["UPDATE_ED_PUBLIC_KEY"])
        env = dict(self.env, UPDATE_ED_PRIVATE_KEY=base64.b64encode(private+public).decode())
        self.run_signer(self.feed, self.work, env=env)
        self.run_signer("--verify", self.feed, self.work)
        env["UPDATE_ED_PRIVATE_KEY"] = base64.b64encode(private+bytes(32)).decode()
        before = self.feed.read_bytes()
        self.run_signer(self.feed, self.work, env=env, ok=False)
        self.assertEqual(self.feed.read_bytes(), before)
        data = copy.deepcopy(self.unsigned)
        other = dict(data["releases"][0]["assets"][0], name="missing.AppImage")
        data["releases"][0]["assets"].append(other)
        self.write(data)
        before = self.feed.read_bytes()
        self.run_signer(self.feed, self.work, ok=False)
        self.assertEqual(self.feed.read_bytes(), before)

    def test_missing_private_key_and_malformed_public_key(self):
        env = dict(self.env, UPDATE_ED_PRIVATE_KEY="")
        self.run_signer(self.feed, self.work, env=env, ok=False)
        env = dict(self.env, UPDATE_ED_PUBLIC_KEY="not a key")
        self.run_signer(self.feed, self.work, env=env, ok=False)

    def test_manifest_embeds_only_public_key_and_refuses_overwrite(self):
        source = self.work / "manifest.json"
        source.write_text(json.dumps({"updates": {"publicEDKey": None}}))
        output = self.work / "build-manifest.json"
        self.run_signer("--prepare-manifest", source, output)
        self.assertEqual(json.loads(output.read_text())["updates"]["publicEDKey"], self.env["UPDATE_ED_PUBLIC_KEY"])
        self.assertNotIn(self.env["UPDATE_ED_PRIVATE_KEY"], output.read_text())
        self.run_signer("--prepare-manifest", source, output, ok=False)
        source.write_text(json.dumps({"updates": {"publicEDKey": base64.b64encode(bytes(32)).decode()}}))
        self.run_signer("--prepare-manifest", source, self.work/"wrong.json", ok=False)

    @unittest.skipUnless(os.environ.get("PD_TEST_PACKAGER"), "set PD_TEST_PACKAGER for runtime-config integration")
    def test_packager_runtime_config_carries_the_throwaway_public_key(self):
        manifest = self.work / "runtime-manifest.json"
        refused = self.work / "real-anchor-must-not-change.json"
        negative = self.run_signer("--prepare-manifest", ROOT/"packaging/package.manifest.json",
                                   refused, ok=False)
        self.assertIn("public key differs from the source manifest", negative.stderr)
        self.assertFalse(refused.exists())
        # The product manifest already pins its real public anchor. Exercise
        # throwaway-key embedding on a private copy without weakening that guard.
        source = self.work / "runtime-source.json"
        fixture = json.loads((ROOT/"packaging/package.manifest.json").read_text())
        fixture["updates"]["publicEDKey"] = None
        source.write_text(json.dumps(fixture))
        self.run_signer("--prepare-manifest", source, manifest)
        script = self.work / "runtime-config.ps1"
        script.write_text('param($Root, $Manifest, $Output)\n'
                          '. (Join-Path $Root "scripts/lib/core.ps1")\n'
                          '$context = Get-GpManifestContext -Path $Manifest\n'
                          'Write-GpUpdateRuntimeConfig -Context $context -Backend "appimage" -MetadataRoot $Output | Out-Null\n')
        env = dict(self.env, UPDATE_ED_PRIVATE_KEY="")
        subprocess.run(["pwsh", "-NoLogo", "-NoProfile", "-File", str(script),
                        os.environ["PD_TEST_PACKAGER"], str(manifest), str(self.work/"metadata")],
                       env=env, check=True, capture_output=True)
        config = json.loads((self.work/"metadata/updates/gnustep-packager-update.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(config["updates"]["publicEDKey"], self.env["UPDATE_ED_PUBLIC_KEY"])
        self.assertEqual(config["package"]["id"], json.loads(manifest.read_text())["package"]["id"])

    @unittest.skipUnless(os.environ.get("PD_TEST_UPDATE_HELPER"), "set PD_TEST_UPDATE_HELPER for independent updater checks")
    def test_updater_refuses_bad_missing_and_applies_valid_local_fixture(self):
        helper = os.environ["PD_TEST_UPDATE_HELPER"]
        signed = self.sign()
        for case in ["bad", "missing", "valid"]:
            with self.subTest(case=case):
                directory = self.work / case
                directory.mkdir()
                current = directory / "current.AppImage"
                current.write_bytes(b"old fixture 0.1.4\n")
                asset = copy.deepcopy(signed["releases"][0]["assets"][0])
                if case == "bad":
                    asset["edSignature"] = base64.b64encode(bytes(64)).decode()
                elif case == "missing":
                    del asset["edSignature"]
                plan = {"package": {"id": self.unsigned["package"]["id"],
                                    "currentVersion": "0.1.4", "channel": "stable",
                                    "publicEDKey": self.env["UPDATE_ED_PUBLIC_KEY"]},
                        "release": {"version": "0.1.5"}, "asset": asset,
                        "execution": {"workingRoot": str(directory), "linux": {"currentAppImagePath": str(current)}}}
                plan_path, state = directory/"plan.json", directory/"state.json"
                plan_path.write_text(json.dumps(plan))
                cmd = [helper, "--mode", "prepare", "--plan", str(plan_path), "--state-file", str(state)]
                p = subprocess.run(cmd, env=self.env, capture_output=True, text=True)
                result = json.loads(state.read_text())
                self.assertEqual(p.returncode == 0, case == "valid", p.stderr)
                self.assertEqual(result["status"], "readyToApply" if case == "valid" else "failed")
                self.assertEqual(current.read_bytes(), b"old fixture 0.1.4\n")
                if case == "valid":
                    p = subprocess.run([helper, "--mode", "apply", "--plan", str(plan_path), "--state-file", str(state)],
                                       env=self.env, capture_output=True, text=True)
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertEqual(json.loads(state.read_text())["status"], "completed")
                    self.assertEqual(current.read_bytes(), self.payload.read_bytes())
                else:
                    self.assertFalse((directory/"downloads"/self.payload.name).exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
