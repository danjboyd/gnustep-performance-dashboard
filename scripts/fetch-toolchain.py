#!/usr/bin/env python3
"""Fetch a digest-locked bootstrap, signed manifest and adjacent payloads.

An existing cache is verified every time. Changed upstream release assets fail
closed; they never silently update the release build's inputs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(destination, platform="linux", metadata_only=False):
    key = "gnustep-toolchain" if platform == "linux" else "gnustep-toolchain-windows"
    lock = json.loads((ROOT / "packaging/release-inputs.json").read_text())[key]
    destination.mkdir(parents=True, exist_ok=True)
    for name, expected in lock["files"].items():
        if metadata_only and name.endswith((".zip", ".tar.gz")):
            continue
        path = destination / name
        if not path.exists():
            temporary = path.with_name(name + ".partial")
            try:
                with urllib.request.urlopen(lock["baseUrl"] + "/" + name, timeout=120) as source, temporary.open("wb") as out:
                    while chunk := source.read(1024 * 1024):
                        out.write(chunk)
                digest = sha256(temporary)
                if digest != expected:
                    raise ValueError(f"{name}: SHA256 mismatch: {digest}")
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        if sha256(path) != expected:
            raise ValueError(f"{name}: cached SHA256 mismatch")
        print(f"{name}: verified {expected}", flush=True)

    # The PowerShell bootstrap only verifies payload hashes. Authenticate the
    # pinned manifest before allowing either platform's bootstrap to run.
    subprocess.run(["openssl", "dgst", "-sha256", "-verify",
                    str(ROOT / "packaging/toolchain-release-public.pem"),
                    "-signature", str(destination / "release-manifest.json.sig"),
                    str(destination / "release-manifest.json")], check=True)
    manifest = json.loads((destination / "release-manifest.json").read_text(encoding="utf-8-sig"))
    artifacts = {artifact["filename"]: artifact["sha256"]
                 for release in manifest["releases"] for artifact in release["artifacts"]}
    for name, expected in lock["files"].items():
        if name.endswith((".zip", ".tar.gz")) and artifacts.get(name) != expected:
            raise ValueError(f"{name}: signed manifest disagrees with the pinned payload digest")
    return lock


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache_directory", type=Path)
    parser.add_argument("--platform", choices=("linux", "windows"), default="linux")
    parser.add_argument("--metadata-only", action="store_true",
                        help="Verify bootstrap and signed metadata without fetching payloads")
    args = parser.parse_args()
    fetch(args.cache_directory.resolve(), args.platform, args.metadata_only)
