#!/usr/bin/env python3
"""Static CSD packaging gates. Never loads or executes the inspected payload."""
import argparse
import hashlib
import json
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
                            check=True, text=True, capture_output=True)
    exported = {fields[-1].split("@", 1)[0] for line in result.stdout.splitlines()
                if len(fields := line.split()) >= 3 and fields[-2].upper() != "U"}
    require(HOOK in exported, "staged GUI lacks defined dynamic export " + HOOK)
    return {"backendSHA256": digest(backend), "guiSHA256": digest(gui),
            "scope": "required strings/export present; visual/runtime correctness unqualified"}


def check_inputs(args):
    lock_path = Path(args.lock).resolve(strict=True)
    lock = json.loads(lock_path.read_text())
    require(lock.get("install_domain") == "LOCAL", "CSD candidate requires reviewed LOCAL layout")
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
    require(provenance.get("elf_files", {}).get(BACK, {}).get("sha256") == backend_sha,
            "backend not tied to SDK ELF provenance")
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("staged")
    stage.add_argument("stage")
    inputs = commands.add_parser("inputs")
    for name in ("lock", "sdk", "backend", "backend-sha256", "theme", "theme-sha256", "theme-receipt"):
        inputs.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        result = check_staged(args.stage) if args.command == "staged" else check_inputs(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("CSD package check FAILED: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
