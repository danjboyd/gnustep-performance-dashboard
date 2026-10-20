#!/usr/bin/env python3
"""Download source packages for the byte-matched staged Windows runtime owners.

No PKGBUILD is executed. Each archive retains the recipe, patches and upstream
sources. Receipts record downloaded hashes; these are not upstream signatures.
"""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("source_inventory", ROOT / "scripts/windows-source-inventory.py")
source_inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_inventory)


def is_license(name):
    return bool(re.fullmatch(r"(?:copying|licen[cs]e|copyright|notice)(?:[._-].*)?", Path(name).name, re.I))


def inspect(path, output):
    """Verify SHA256-pinned recipe inputs and copy preserved license texts."""
    licenses, verified = [], []
    with tarfile.open(path, "r:*") as archive:
        members = {Path(m.name).name: m for m in archive if m.isfile()}
        if ".SRCINFO" not in members or "PKGBUILD" not in members:
            raise ValueError(f"Missing recipe metadata: {path.name}")
        info = archive.extractfile(members[".SRCINFO"]).read().decode()
        sources, checksums = [], []
        for line in info.splitlines():
            key, separator, value = line.strip().partition(" = ")
            if separator and (key == "source" or key.startswith("source_")):
                sources.append(value.split("::", 1)[0] if "::" in value else value.rsplit("/", 1)[-1])
            if separator and (key == "sha256sums" or key.startswith("sha256sums_")):
                checksums.append(value)
        if len(sources) != len(checksums):
            raise ValueError(f"Unmatched source/SHA256 recipe lists: {path.name}")
        for name, expected in zip(sources, checksums):
            if expected == "SKIP":
                continue
            if name not in members:
                raise ValueError(f"Missing recipe input {name}: {path.name}")
            actual = hashlib.sha256(archive.extractfile(members[name]).read()).hexdigest()
            if actual != expected:
                raise ValueError(f"Recipe SHA256 mismatch for {name}: {path.name}")
            verified.append(name)
        # Inspect tar inputs in memory, never extract arbitrary paths to disk.
        for member in members.values():
            data = archive.extractfile(member).read()
            if is_license(member.name):
                destination = output / (str(len(licenses)) + "-" + Path(member.name).name)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                licenses.append({"file": destination.name, "archiveMember": member.name,
                                 "sha256": hashlib.sha256(data).hexdigest()})
            if member.name.endswith((".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".tar.zst")):
                with tarfile.open(fileobj=io.BytesIO(data)) as upstream:
                    for item in upstream:
                        if item.isfile() and is_license(item.name):
                            destination = output / (str(len(licenses)) + "-" + Path(item.name).name)
                            destination.parent.mkdir(parents=True, exist_ok=True)
                            destination.write_bytes(upstream.extractfile(item).read())
                            licenses.append({"file": destination.name,
                                             "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
                                             "archiveMember": member.name + ":" + item.name})
    return verified, licenses


def prepare(stage, toolchain_source, output):
    runtime = json.loads((stage / "metadata/windows-runtime-inventory.json").read_text())
    directory = toolchain_source / "toolchains/windows-amd64-msys2-clang64"
    owners = [p["name"] for p in runtime["packages"]]
    lock = json.loads((directory / "input-manifest.json").read_text())
    result = source_inventory.inventory(lock, directory / "msys2-sync", owners)
    core = json.loads((ROOT / "packaging/windows-core-sources.json").read_text())
    pinned = {s["base"]: s["sha256"] for s in core["sources"]}
    runtime_lock = json.loads((ROOT / "packaging/windows-runtime-sources.json").read_text())
    pins = {(s["base"], s["version"]): s for s in runtime_lock["sources"]}
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for entry in result["sources"]:
        pin = pins.get((entry["base"], entry["version"]))
        if not pin or not set(entry["binaryPackages"]).issubset(pin["binaryPackages"]):
            raise ValueError(f"Runtime source is not pinned: {entry['base']} {entry['version']}")
        url = entry["candidateUrl"]
        path = output / url.rsplit("/", 1)[-1]
        receipt = path.with_suffix(path.suffix + ".json")
        if not path.exists():
            partial = path.with_suffix(path.suffix + ".partial")
            try:
                with urllib.request.urlopen(url, timeout=120) as source, partial.open("wb") as target:
                    shutil.copyfileobj(source, target)
                partial.replace(path)
            finally:
                partial.unlink(missing_ok=True)
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        previous = json.loads(receipt.read_text()) if receipt.exists() else None
        if (sha != pin["sha256"] or path.stat().st_size != pin["sizeBytes"] or
                (entry["base"] in pinned and pinned[entry["base"]] != sha) or
                (previous and previous["sha256"] != sha)):
            raise ValueError(f"Source archive changed: {path.name}")
        verified, licenses = inspect(path, output / "licenses" / entry["base"])
        entry.update(sha256=sha, sizeBytes=path.stat().st_size, filename=path.name,
                     verifiedRecipeInputs=verified, extractedLicenses=licenses,
                     verification="Recipe SHA256 inputs verified; no recipe executed; archive signature not verified")
        receipt.write_text(json.dumps(entry, indent=2) + "\n", encoding="utf-8")
        records.append(entry)
        (output / "sources.json").write_text(json.dumps({"sources": records}, indent=2) + "\n", encoding="utf-8")
        print(f"Verified recipe inputs: {path.name}; {len(licenses)} license files", flush=True)
    return records


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--toolchain-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.stage, args.toolchain_source, args.output)
