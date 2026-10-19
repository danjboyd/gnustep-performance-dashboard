#!/usr/bin/env python3
"""Fetch a digest-locked bootstrap, signed manifest and adjacent payloads.

An existing cache is verified every time. Changed upstream release assets fail
closed; they never silently update the release build's inputs.
"""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request


def fetch(destination):
    lock = json.loads((Path(__file__).resolve().parents[1] /
                       "packaging/release-inputs.json").read_text())["gnustep-toolchain"]
    destination.mkdir(parents=True, exist_ok=True)
    for name, expected in lock["files"].items():
        path = destination / name
        if not path.exists():
            temporary = path.with_name(name + ".partial")
            try:
                with urllib.request.urlopen(lock["baseUrl"] + "/" + name) as source, temporary.open("wb") as out:
                    while chunk := source.read(1024 * 1024):
                        out.write(chunk)
                digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
                if digest != expected:
                    raise ValueError(f"{name}: SHA256 mismatch: {digest}")
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"{name}: cached SHA256 mismatch")
        print(f"{name}: verified {expected}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: fetch-toolchain.py CACHE_DIRECTORY")
    fetch(Path(sys.argv[1]).resolve())
