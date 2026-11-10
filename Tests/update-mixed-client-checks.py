#!/usr/bin/env python3
"""Real old/new feed parsers and helpers; throwaway keys and tiny shell files.

Keep the historical v0.1.5 ledger unchanged in an archived source checkout.
No product keys, network, installed app, AppImage or GUI acceptance is involved.
Run only in a fresh private passwd home. This script builds its old-client
fixture when explicitly invoked; source preparation does not run it.
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
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OLD_COMMIT = "3af51b1ae7b717720e176d2302ded3fea14c347a"
PACKAGE = "io.github.danjboyd.MixedClientFixture"


def run(command, **kwargs):
    result = subprocess.run(list(map(str, command)), capture_output=True, timeout=180, **kwargs)
    if result.returncode:
        error = result.stderr if isinstance(result.stderr, str) else result.stderr.decode(errors="replace")
        raise RuntimeError(f"{Path(str(command[0])).name} exited {result.returncode}: {error}")
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_adapter(root, output, env):
    core = root / "third_party/gnustep-packager-updater/objc/GPUpdaterCore"
    flags = shlex.split(run(["gnustep-config", "--objc-flags"], text=True).stdout)
    libs = shlex.split(run(["gnustep-config", "--base-libs"], text=True).stdout)
    run(["clang", *flags, "-fobjc-arc", "-I"+str(core/"Headers"),
         root/"Tests/fixtures/update-feed-plan.m", core/"libGPUpdaterCore.a",
         "-o", output, *libs], env=env)


def canonical_vector(directory, env):
    # Both implementations verify the same published fixed signature/vector.
    run([sys.executable, ROOT/"Tests/update-signing-checks.py",
         "SigningChecks.test_packager_published_canonical_vector"], env=env)
    core = ROOT/"third_party/gnustep-packager-updater/objc/GPUpdaterCore"
    mono = core.parent/"gp-update-helper/Source/monocypher"
    objects = []
    for name in ("monocypher", "monocypher-ed25519"):
        output = directory/(name+".o")
        run(["clang", "-O2", "-I"+str(mono), "-c", mono/(name+".c"), "-o", output], env=env)
        objects.append(output)
    flags = shlex.split(run(["gnustep-config", "--objc-flags"], text=True).stdout)
    libs = shlex.split(run(["gnustep-config", "--base-libs"], text=True).stdout)
    program = directory/"version-vector"
    run(["clang", *flags, "-fobjc-arc", "-I"+str(core/"Headers"), "-I"+str(mono),
         ROOT/"Tests/fixtures/update-version-vector.m", core/"libGPUpdaterCore.a",
         *objects, "-o", program, *libs], env=env)
    message = directory/"canonical-message.bin"
    run([program, message], env=env)
    expected = ("gnustep-packager-update-v1\ncom.example.MyGNUstepApp\n1.2.3\nstable\nwindows-x64\n"
                "110499c3d4d34a94a1ea70ae7e7353d32708e043bc0ccee13ec9fbdb7a9d20b1").encode()
    assert message.read_bytes() == expected and len(expected) == 141
    return {"status": "PASS", "messageSHA256": digest(message),
            "objcAdapterSHA256": digest(program), "publishedVector": "packager v0.1.10"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path,
                        default=ROOT/"Dashboard/PerformanceDashboard.app/gp-update-helper")
    parser.add_argument("--output", type=Path, default=ROOT/"Tests/out/update-mixed-client")
    args = parser.parse_args()
    run([sys.executable, ROOT/"scripts/with-private-home.py", "--check"])
    helper = args.helper.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    legacy = evidence/"v015-source"
    legacy.mkdir()
    archive = evidence/"v015-source.tar"
    paths = ["third_party/gnustep-packager-updater", "scripts/sign-update-feed.py",
             "Tests/update-chain-checks.py", "Tests/fixtures/update-feed-plan.m"]
    archive.write_bytes(run(["git", "-C", ROOT, "archive", OLD_COMMIT, *paths]).stdout)
    with tarfile.open(archive) as source:
        source.extractall(legacy, filter="data")
    old_objc = legacy/"third_party/gnustep-packager-updater/objc"
    # Remove inherited product signing inputs without ever inspecting them.
    clean = {k: v for k, v in os.environ.items()
             if k not in ("UPDATE_ED_PRIVATE_KEY", "UPDATE_ED_PUBLIC_KEY")}
    vector = canonical_vector(evidence, clean)
    for component in ("GPUpdaterCore", "gp-update-helper"):
        run(["make", "-C", old_objc/component, "-j2", "all"], env=clean)
    old_helper = old_objc/"gp-update-helper/gp-update-helper"
    old_receipt = evidence/"v015-historical-ledger.json"
    run([sys.executable, legacy/"Tests/update-chain-checks.py", "--helper", old_helper,
         "--receipt", old_receipt], env=clean)
    # The archived script deliberately retains its old metadata-bump acceptance.
    historical = json.loads(old_receipt.read_text())
    observed = {case["case"]: case for case in historical["cases"]}
    assert observed["metadata-only-edit"]["prepare"] == "readyToApply"
    assert observed["signed-older-payload"]["apply"] == "completed"
    old_driver, new_driver = evidence/"v015-feed-plan", evidence/"v016-feed-plan"
    compile_adapter(legacy, old_driver, clean)
    compile_adapter(ROOT, new_driver, clean)
    receipt = {"scope": "source-built v0.1.5 and candidate feed parsers/helpers with shell fixtures",
               "legacyCommit": OLD_COMMIT, "legacyLedger": old_receipt.name,
               "v015HelperSHA256": digest(old_helper), "newHelperSHA256": digest(helper),
               "v015CoreSHA256": digest(old_objc/"GPUpdaterCore/libGPUpdaterCore.a"),
               "newCoreSHA256": digest(ROOT/"third_party/gnustep-packager-updater/objc/GPUpdaterCore/libGPUpdaterCore.a"),
               "scriptSHA256": digest(Path(__file__)), "canonicalVector": vector, "cases": []}
    with tempfile.TemporaryDirectory(prefix="pd-mixed-key-") as private:
        work = Path(private)
        key = work/"throwaway.pem"
        run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", key], env=clean)
        key.chmod(0o600)
        seed = run(["openssl", "pkey", "-in", key, "-outform", "DER"]).stdout[-32:]
        public = run(["openssl", "pkey", "-in", key, "-pubout", "-outform", "DER"]).stdout[-32:]
        env = dict(clean, UPDATE_ED_PRIVATE_KEY=base64.b64encode(seed).decode(),
                   UPDATE_ED_PUBLIC_KEY=base64.b64encode(public).decode())
        payload = work/"fixture.AppImage"
        feed_path = work/"feed.json"
        cases = ["v015-to-v016", "v016-to-v017", "relabelled-older",
                 "metadata-only-bump", "older-replay", "equal-replay", "missing-version-signature"]
        for case in cases:
            old_client = case == "v015-to-v016"
            current_version = "0.1.5" if old_client else "0.1.6"
            signed_version = "0.1.6" if old_client else "0.1.7"
            if case in ("relabelled-older", "older-replay"): signed_version = "0.1.4"
            if case == "equal-replay": signed_version = current_version
            data = ("#!/bin/sh\n# fixture version: "+signed_version+"\nexit 0\n").encode()
            payload.write_bytes(data)
            asset = {"backend": "appimage", "platform": "linux-x64", "name": payload.name,
                     "url": payload.as_uri(), "sha256": digest(payload), "sizeBytes": len(data)}
            feed = {"formatVersion": 1, "channel": "stable", "package": {"id": PACKAGE},
                    "releases": [{"version": signed_version, "tag": "v"+signed_version, "assets": [asset]}]}
            feed_path.write_text(json.dumps(feed))
            run([sys.executable, ROOT/"scripts/sign-update-feed.py", feed_path, work], env=env)
            feed = json.loads(feed_path.read_text())
            if case == "relabelled-older":
                feed["releases"][0].update(version="0.1.7", tag="v0.1.7")
            elif case == "metadata-only-bump":
                feed["releases"][0].update(version="0.1.7.1", tag="v0.1.7.1")
            elif case == "missing-version-signature":
                del feed["releases"][0]["assets"][0]["versionSignature"]
            feed_path.write_text(json.dumps(feed))
            directory = work/case
            directory.mkdir()
            current = directory/"current.AppImage"
            installed = ("#!/bin/sh\n# installed version: "+current_version+"\nexit 0\n").encode()
            current.write_bytes(installed)
            current.chmod(0o755)
            config = {"package": {"id": PACKAGE, "name": "MixedClientFixture",
                       "version": current_version, "backend": "appimage"},
                      "updates": {"channel": "stable", "feedUrl": feed_path.as_uri(),
                                  "publicEDKey": env["UPDATE_ED_PUBLIC_KEY"]},
                      "execution": {"workingRoot": str(directory),
                                    "linux": {"currentAppImagePath": str(current)}}}
            config_path, plan_path, state = directory/"config.json", directory/"plan.json", directory/"state.json"
            config_path.write_text(json.dumps(config))
            selected = subprocess.run([str(old_driver if old_client else new_driver),
                str(config_path), str(plan_path)], env=env, capture_output=True, text=True, timeout=30)
            replay = case in ("older-replay", "equal-replay")
            assert selected.returncode == (6 if replay else 0), (case, selected.stderr)
            if replay:
                # Independently check helper's monotonic guard as well as Core selection.
                plan = {"package": {"id": PACKAGE, "currentVersion": current_version,
                        "channel": "stable", "publicEDKey": env["UPDATE_ED_PUBLIC_KEY"]},
                        "release": {"version": signed_version},
                        "asset": feed["releases"][0]["assets"][0], "execution": config["execution"]}
                plan_path.write_text(json.dumps(plan))
            client_helper = old_helper if old_client else helper
            prepared = subprocess.run([str(client_helper), "--mode", "prepare", "--plan", str(plan_path),
                "--state-file", str(state)], env=env, capture_output=True, text=True, timeout=30)
            status = json.loads(state.read_text())
            positive = case in ("v015-to-v016", "v016-to-v017")
            assert (prepared.returncode == 0) == positive, (case, status)
            assert status["status"] == ("readyToApply" if positive else "failed"), (case, status)
            assert current.read_bytes() == installed, case
            observation = {"case": case, "client": "v015" if old_client else "candidate-v016",
                           "prepare": status["status"], "selection": "no-update" if replay else "offered",
                           "installedUnchangedAfterPrepare": True}
            if positive:
                run([client_helper, "--mode", "apply", "--plan", plan_path, "--state-file", state], env=env)
                assert json.loads(state.read_text())["status"] == "completed", case
                assert current.read_bytes() == data, case
                observation.update(apply="completed", installedSHA256=digest(current))
            else:
                error = status.get("error", {}).get("message", "")
                assert ("not newer" in error) if replay else ("version" in error.lower()), (case, status)
                observation.update(installedUnchangedAfterRefusal=True, refusal=error)
            receipt["cases"].append(observation)
            (evidence/"mixed-client-receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
            print(case, observation["prepare"], flush=True)
    receipt["limits"] = ["Source-built updater clients, not real AppImages or GUI relaunch acceptance.",
        "Old-client metadata acceptance remains a documented limitation.",
        "No signatures on notes/URLs/freshness, and no key rotation/revocation contract."]
    (evidence/"mixed-client-receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
    print("Mixed-client evidence:", evidence)


if __name__ == "__main__":
    main()
