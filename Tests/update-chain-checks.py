#!/usr/bin/env python3
"""Local 0.1.5 -> test 0.1.6 chain through real feed selection and helper.

Fresh throwaway key and shell payloads only; no AppImage build, product key,
network, real installation or GUI-relaunch acceptance. Requires make's built
GPUpdaterCore and gp-update-helper. Metadata/rollback observations deliberately
document the current asset-only signature boundary rather than fixing it.
"""
import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "third_party/gnustep-packager-updater/objc/GPUpdaterCore"


def run(args, **kwargs):
    result = subprocess.run(list(map(str, args)), capture_output=True, **kwargs)
    if result.returncode:
        error = result.stderr if isinstance(result.stderr, str) else result.stderr.decode(errors="replace")
        raise RuntimeError(f"{Path(args[0]).name} exited {result.returncode}: {error}")
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        default=ROOT/"Dashboard/PerformanceDashboard.app/gp-update-helper")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    helper = args.helper.resolve(strict=True)
    receipt = {"scope": "local shell fixtures, actual GPUpdaterCore feed parser and v0.1.5-built helper",
               "helperSHA256": digest(helper.read_bytes()),
               "helperSourceSHA256": digest((CORE.parent/"gp-update-helper/Source/main.m").read_bytes()),
               "coreArchiveSHA256": digest((CORE/"libGPUpdaterCore.a").read_bytes()),
               "testScriptSHA256": digest(Path(__file__).read_bytes()),
               "feedAdapterSHA256": digest((ROOT/"Tests/fixtures/update-feed-plan.m").read_bytes()),
               "cases": []}
    with tempfile.TemporaryDirectory(prefix="pd-update-chain-") as temporary:
        work = Path(temporary)
        driver = work/"feed-plan"
        flags = shlex.split(run(["gnustep-config", "--objc-flags"], text=True).stdout)
        libs = shlex.split(run(["gnustep-config", "--base-libs"], text=True).stdout)
        run(["clang", *flags, "-fobjc-arc", "-I"+str(CORE/"Headers"),
             ROOT/"Tests/fixtures/update-feed-plan.m", CORE/"libGPUpdaterCore.a",
             "-o", driver, *libs])
        key = work/"throwaway.pem"
        run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", key])
        key.chmod(0o600)
        private = run(["openssl", "pkey", "-in", key, "-outform", "DER"]).stdout[-32:]
        public = run(["openssl", "pkey", "-in", key, "-pubout", "-outform", "DER"]).stdout[-32:]
        environment = dict(os.environ, UPDATE_ED_PRIVATE_KEY=base64.b64encode(private).decode(),
                           UPDATE_ED_PUBLIC_KEY=base64.b64encode(public).decode())
        tool = work/"bin/appimageupdatetool"
        tool.parent.mkdir()
        marker = work/"alternate-tool-called"
        tool.write_text("#!/bin/sh\ntouch '"+str(marker)+"'\nexit 91\n")
        tool.chmod(0o755)
        environment["PATH"] = str(tool.parent)+os.pathsep+environment["PATH"]
        payload = work/"PerformanceDashboard-0.1.6-test.AppImage"
        feed_path = work/"test-feed.json"
        new = b"#!/bin/sh\n# fixture version: 0.1.6-test\nexit 0\n"
        old = b"#!/bin/sh\n# fixture version: 0.1.4-test\nexit 0\n"
        installed = b"#!/bin/sh\n# fixture version: 0.1.5\nexit 0\n"

        def signed_feed(data):
            payload.write_bytes(data)
            asset = {"backend": "appimage", "platform": "linux-x64", "name": payload.name,
                     "url": payload.as_uri(), "sizeBytes": len(data), "sha256": digest(data)}
            feed = {"formatVersion": 1, "channel": "stable", "releases": [
                {"version": "0.1.6", "tag": "v0.1.6", "assets": [asset]}]}
            feed_path.write_text(json.dumps(feed))
            run([sys.executable, ROOT/"scripts/sign-update-feed.py", feed_path, work], env=environment)
            return json.loads(feed_path.read_text())

        good = signed_feed(new)
        for case in ["valid", "tampered-asset", "tampered-feed-signature",
                     "tampered-asset-and-feed-hash", "missing-feed-signature",
                     "metadata-only-edit", "signed-older-payload", "legacy-no-key-tool"]:
            directory = work/case
            directory.mkdir()
            current = directory/"current.AppImage"
            current.write_bytes(installed)
            current.chmod(0o755)
            payload.write_bytes(new)
            feed = copy.deepcopy(good)
            asset = feed["releases"][0]["assets"][0]
            if case in ("tampered-asset", "tampered-asset-and-feed-hash"):
                payload.write_bytes(new+b"# changed after signing\n")
                if case == "tampered-asset-and-feed-hash":
                    asset["sha256"] = digest(payload.read_bytes())
                    asset["sizeBytes"] = payload.stat().st_size
            elif case == "tampered-feed-signature":
                asset["edSignature"] = base64.b64encode(bytes(64)).decode()
            elif case == "missing-feed-signature":
                del asset["edSignature"]
            elif case == "metadata-only-edit":
                feed["releases"][0]["version"] = "0.1.6.1"
                feed["releases"][0]["tag"] = "v0.1.6.1"
            elif case == "signed-older-payload":
                # Genuine signature of older fixture bytes, advertised as 0.1.6.
                feed = signed_feed(old)
            feed_path.write_text(json.dumps(feed))
            config = {"package": {"id": "io.github.danjboyd.UpdateChainFixture."+case,
                      "name": "UpdateChainFixture", "version": "0.1.5", "backend": "appimage"},
                      "updates": {"channel": "stable", "feedUrl": feed_path.as_uri()},
                      "execution": {"workingRoot": str(directory),
                                    "linux": {"currentAppImagePath": str(current)}}}
            if case != "legacy-no-key-tool":
                config["updates"]["publicEDKey"] = environment["UPDATE_ED_PUBLIC_KEY"]
            config_path, plan_path, state = directory/"config.json", directory/"plan.json", directory/"state.json"
            config_path.write_text(json.dumps(config))
            selection = run([driver, config_path, plan_path], env=environment, text=True)
            plan = json.loads(plan_path.read_text())
            p = subprocess.run([str(helper), "--mode", "prepare", "--plan", str(plan_path),
                                "--state-file", str(state)], env=environment, capture_output=True)
            status = json.loads(state.read_text())
            refused = case.startswith("tampered-") or case == "missing-feed-signature"
            assert (p.returncode != 0) == refused, (case, p.returncode, status)
            assert status["status"] == ("failed" if refused else "readyToApply"), (case, status)
            assert current.read_bytes() == installed, case
            observation = {"case": case, "selectedVersion": plan["release"]["version"],
                           "prepare": status["status"], "installedUnchangedAfterPrepare": True}
            if refused:
                observation["rejectedDownloadRemoved"] = not (directory/"downloads"/payload.name).exists()
                # Hash-mismatch downloads are currently retained, unlike
                # signature failures. Installed bytes must remain untouched.
                if case != "tampered-asset":
                    assert observation["rejectedDownloadRemoved"], case
            elif case in ("valid", "signed-older-payload"):
                run([helper, "--mode", "apply", "--plan", plan_path, "--state-file", state], env=environment)
                assert json.loads(state.read_text())["status"] == "completed", case
                expected = old if case == "signed-older-payload" else new
                assert current.read_bytes() == expected, case
                observation["apply"] = "completed"
                observation["installedSHA256"] = digest(current.read_bytes())
                observation["payloadFixtureVersion"] = "0.1.4-test" if case == "signed-older-payload" else "0.1.6-test"
            elif case == "legacy-no-key-tool":
                assert status["apply"]["mode"] == "appimage-update", status
                p = subprocess.run([str(helper), "--mode", "apply", "--plan", str(plan_path),
                                    "--state-file", str(state)], env=environment, capture_output=True)
                assert p.returncode != 0 and json.loads(state.read_text())["status"] == "failed"
                assert marker.exists() and current.read_bytes() == installed
                observation["apply"] = "tool failed; installed unchanged; no download fallback"
            if case != "legacy-no-key-tool":
                assert not marker.exists(), "keyed helper must skip alternate tool"
            receipt["cases"].append(observation)
            print(selection.stdout.strip()+": "+case+" -> "+observation.get("apply", status["status"]))
    receipt["limits"] = ["Asset bytes are signed; feed metadata is not authenticated.",
        "A correctly signed older fixture advertised as new was installed; no payload-version comparison observed.",
        "Synthetic shell fixtures, not an actual candidate AppImage or GUI relaunch acceptance."]
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, indent=2)+"\n")
    print("All 8 local update-chain scenarios matched the recorded behavior; metadata/rollback limits remain.")


if __name__ == "__main__":
    main()
