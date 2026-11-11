#!/usr/bin/env python3
"""Static CSD packaging gates. Never loads or executes the inspected payload."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BACK = "Local/Library/Bundles/libgnustep-back-032.bundle/libgnustep-back-032"
GUI = "runtime/lib/libgnustep-gui.so.0.32"
STAGED_BACK = "runtime/System/Library/Bundles/libgnustep-back-032.bundle/libgnustep-back-032"
HOOK = "GSThemeInstallBackendDefaults"
KEYS = (b"GSBackWindowShadows", b"GSBackWindowCornerRadius")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verified_digest(path, expected, label):
    require(bool(re.fullmatch(r"[0-9a-f]{64}", expected)), label + " needs an explicit SHA-256")
    actual = digest(path)
    require(actual == expected, label + " SHA-256 mismatch")
    return actual


def inside(root, path):
    path = Path(path).resolve(strict=True)
    require(path.is_relative_to(root.resolve()), "payload path escapes its owned root")
    return path


def check_staged(stage):
    stage = Path(stage).resolve(strict=True)
    backend = inside(stage, stage / STAGED_BACK)
    gui = inside(stage, stage / GUI)
    backend_bytes = backend.read_bytes()
    require(backend_bytes.startswith(b"\x7fELF"), "backend is not ELF")
    for key in KEYS:
        require(key in backend_bytes, "staged backend lacks " + key.decode())
    with gui.open("rb") as source:
        require(source.read(4) == b"\x7fELF", "GUI library is not ELF")
    result = subprocess.run(["nm", "-D", "--defined-only", str(gui)],
                            check=True, text=True, capture_output=True, timeout=10)
    exported = {fields[-1].split("@", 1)[0] for line in result.stdout.splitlines()
                if len(fields := line.split()) >= 3 and fields[-2].upper() != "U"}
    require(HOOK in exported, "staged GUI lacks defined dynamic export " + HOOK)
    return {"backendSHA256": digest(backend), "guiSHA256": digest(gui),
            "scope": "required strings/export present; visual/runtime correctness unqualified"}


def check_inputs(args):
    lock_path = Path(args.lock).resolve(strict=True)
    lock = json.loads(lock_path.read_text())
    require(lock.get("schema_version") == 1 and lock.get("kind") == "custom-toolchain-lock",
            "custom lock format mismatch")
    require([component["name"] for component in lock["components"]] ==
            ["libobjc2", "libdispatch", "tools-make", "libs-base", "libs-corebase", "libs-gui", "libs-back"],
            "CSD candidate requires the exact seven-component inventory/order")
    require(lock.get("install_domain") == "LOCAL", "CSD candidate requires reviewed LOCAL layout")
    review_name = lock.get("pd_review", {}).get("review_inputs")
    review_path = getattr(args, "review_inputs", None)
    if not review_path and review_name:
        review_path = inside(lock_path.parent, lock_path.parent / review_name)
    if review_path:
        review = check_review_inputs(review_path)
        require(review["lockSHA256"] == digest(lock_path), "review manifest names another lock")
    sdk = Path(args.sdk).resolve(strict=True)
    provenance_path = sdk / "gnustep-toolchain-provenance.json"
    provenance = json.loads(provenance_path.read_text())
    lock_sha = digest(lock_path)
    require(provenance.get("schema_version") == 1
            and provenance.get("kind") == "custom-gnustep-toolchain-provenance",
            "custom SDK provenance format mismatch")
    require(provenance.get("official") is False, "custom SDK must declare official=false")
    require(provenance.get("lock", {}).get("sha256") == lock_sha, "SDK lock identity mismatch")
    require(provenance.get("install_domain") == "LOCAL", "SDK domain mismatch")
    for component in lock["components"]:
        for patch in component.get("patches", []):
            path = inside(lock_path.parent, lock_path.parent / patch["path"])
            verified_digest(path, patch["sha256"], "patch " + patch["path"])
    components = provenance.get("components", [])
    require(len(components) == len(lock["components"]), "SDK component count mismatch")
    for expected, actual in zip(lock["components"], components):
        require(actual.get("name") == expected["name"]
                and actual.get("url") == expected["url"]
                and actual.get("resolved_commit") == expected["revision"]
                and actual.get("revision") == expected["revision"]
                and actual.get("configure_args", []) == expected.get("configure_args", [])
                and actual.get("applied_patches", []) == expected.get("patches", []),
                "SDK source/patch/configuration mismatch for " + expected["name"])
    backend = inside(sdk, Path(args.backend) / "libgnustep-back-032")
    require(backend == (sdk / BACK).resolve(strict=True), "explicit backend is not this SDK's exact bundle")
    backend_sha = verified_digest(backend, args.backend_sha256, "backend")
    require(provenance.get("elf_files", {}).get(str(backend.relative_to(sdk)), {}).get("sha256") == backend_sha,
            "backend not tied to SDK ELF provenance")
    if review_path:
        manifest_path = Path(review_path).resolve(strict=True)
        policy_name = json.loads(manifest_path.read_text())["backendNeededPolicy"]["path"]
        policy_path = inside(manifest_path.parent, manifest_path.parent / policy_name)
        link_log = os.environ.get("PD_CSD_BACKEND_LINK_LOG")
        require(link_log, "combined CSD inputs require PD_CSD_BACKEND_LINK_LOG")
        check_backend_needed(backend, policy_path, link_log)
    theme = Path(args.theme).resolve(strict=True) / "Adwaita"
    theme_sha = verified_digest(theme, args.theme_sha256, "theme")
    receipt = json.loads(Path(args.theme_receipt).read_text())
    require(receipt.get("schemaVersion") == 1
            and receipt.get("themeBinarySHA256") == theme_sha
            and receipt.get("toolchainLockSHA256") == lock_sha
            and receipt.get("toolchainProvenanceSHA256") == digest(provenance_path),
            "theme build receipt does not bind this binary to this SDK identity")
    release_inputs = json.loads((Path(__file__).resolve().parents[1] / "packaging/release-inputs.json").read_text())
    require(receipt.get("themeSourceRevision") == release_inputs["adwaita"]["revision"],
            "theme source revision mismatch")
    return {"lockSHA256": lock_sha, "backendSHA256": backend_sha, "themeSHA256": theme_sha,
            "scope": "input identity checks only; rebuild origin requires reviewed build receipt/logs"}


def check_review_inputs(manifest_path):
    manifest_path = Path(manifest_path).resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get("schemaVersion") == 1 and manifest.get("kind") == "pd-csd-review-inputs",
            "review input manifest format mismatch")
    record = manifest["toolchainLock"]
    lock_path = inside(manifest_path.parent, manifest_path.parent / record["path"])
    lock_sha = verified_digest(lock_path, record["sha256"], "review lock")
    lock = json.loads(lock_path.read_text())
    require(lock.get("install_domain") == "LOCAL", "review lock domain mismatch")
    require("libxfixes-dev" in lock.get("container", {}).get("apt_packages", []),
            "review image lacks explicit XFixes development input")
    counts = {component["name"]: len(component.get("patches", [])) for component in lock["components"]}
    expected_counts = {"libobjc2": 0, "libdispatch": 0, "tools-make": 0,
                       "libs-base": 8, "libs-corebase": 0, "libs-gui": 1, "libs-back": 7}
    require([component["name"] for component in lock["components"]] == list(expected_counts)
            and counts == expected_counts and manifest.get("sdkPatchCounts") == counts,
            "combined SDK patch inventory mismatch")
    order = [{"component": component["name"], **patch}
             for component in lock["components"] for patch in component.get("patches", [])]
    require(len(order) == 16 and manifest.get("sdkPatchCount") == 16
            and manifest.get("sdkPatchOrder") == order, "combined SDK patch order/count mismatch")
    order_sha = hashlib.sha256(json.dumps(order, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    require(manifest.get("sdkPatchOrderSHA256") == order_sha, "combined SDK patch order digest mismatch")
    backend = next(component for component in lock["components"] if component["name"] == "libs-back")
    require(not any(value.startswith("ac_cv_lib_Xfixes_") for value in backend.get("configure_args", [])),
            "review lock forces an XFixes configure answer")
    for patch in order:
        verified_digest(inside(lock_path.parent, lock_path.parent / patch["path"]),
                        patch["sha256"], "review patch " + patch["path"])
    application = manifest.get("applicationPatches", [])
    require(len(application) == 1, "one separately bound application patch required")
    require(manifest.get("reviewedPatchCount") == len(order) + len(application) == 17,
            "combined reviewed patch count mismatch")
    for patch in application:
        verified_digest(inside(root, root / patch["path"]), patch["sha256"], "application patch")
        source = patch["appliedSource"]
        verified_digest(inside(root, root / source["path"]), source["sha256"], "applied application source")
    policy_record = manifest["backendNeededPolicy"]
    policy_path = inside(manifest_path.parent, manifest_path.parent / policy_record["path"])
    verified_digest(policy_path, policy_record["sha256"], "backend dependency policy")
    policy = json.loads(policy_path.read_text())
    require(set(policy["expectedNeeded"]) == set(policy["retainedNeeded"]) | {"libXfixes.so.3"}
            and len(policy["expectedNeeded"]) == len(set(policy["expectedNeeded"]))
            and "libXft.so.2" not in policy["expectedNeeded"]
            and "libXt.so.6" not in policy["expectedNeeded"], "backend dependency baseline is not exact retained plus XFixes")
    return {"lockSHA256": lock_sha, "reviewInputsSHA256": digest(manifest_path),
            "sdkPatchCount": len(order), "applicationPatchCount": len(application),
            "scope": "combined source input identities only; no build/runtime qualification"}


def check_backend_needed(backend, policy_path, link_log):
    policy = json.loads(Path(policy_path).read_text())
    log = Path(link_log)
    require(log.is_file() and log.stat().st_size > 0, "executed backend link log required")
    result = subprocess.run(["readelf", "-d", str(backend)], check=True,
                            capture_output=True, text=True, timeout=10)
    needed = sorted(re.findall(r"\(NEEDED\).*?\[([^]]+)\]", result.stdout))
    require(needed == sorted(policy["expectedNeeded"]),
            "backend DT_NEEDED differs from exact retained baseline plus XFixes")
    return {"backendSHA256": digest(backend), "needed": needed,
            "policySHA256": digest(policy_path), "linkLogSHA256": digest(log),
            "scope": "exact direct-library gate; inspect executed link command and transitive closure separately"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("staged")
    stage.add_argument("stage")
    inputs = commands.add_parser("inputs")
    for name in ("lock", "sdk", "backend", "backend-sha256", "theme", "theme-sha256", "theme-receipt"):
        inputs.add_argument("--" + name, required=True)
    inputs.add_argument("--review-inputs")
    review = commands.add_parser("review-inputs")
    review.add_argument("manifest")
    needed = commands.add_parser("backend-needed")
    for name in ("backend", "policy", "link-log"):
        needed.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        if args.command == "staged":
            result = check_staged(args.stage)
        elif args.command == "inputs":
            result = check_inputs(args)
        elif args.command == "review-inputs":
            result = check_review_inputs(args.manifest)
        else:
            result = check_backend_needed(args.backend, args.policy, args.link_log)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("CSD package check FAILED: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
