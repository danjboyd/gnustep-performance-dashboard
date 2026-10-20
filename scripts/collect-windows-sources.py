#!/usr/bin/env python3
"""Archive the application, package sources and pinned Windows assembly recipes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def collect(version, output, source_cache, toolchain_source, theme, packager):
    runtime = json.loads((ROOT / "dist/stage/metadata/windows-runtime-inventory.json").read_text())
    if runtime["missingLicenseTexts"]:
        raise ValueError("Staged runtime still has missing license texts")
    sources = json.loads((source_cache / "sources.json").read_text())
    covered = {name for entry in sources["sources"] for name in entry["binaryPackages"]}
    required = {entry["name"] for entry in runtime["packages"]}
    if covered != required:
        raise ValueError("Source package owners differ from staged runtime owners")
    work = ROOT / "out/windows-source-archives"
    work.mkdir(parents=True, exist_ok=True)
    archives = []
    for name, repository in (("PerformanceDashboard", ROOT), ("gnustep-cli-new", toolchain_source),
                             ("WinUITheme", theme), ("gnustep-packager", packager)):
        path = work / (name + ".tar")
        subprocess.run(["git", "-C", str(repository), "archive", "--format=tar",
                        "--prefix=" + name + "/", "-o", str(path), "HEAD"], check=True)
        archives.append(path)
    for entry in sources["sources"]:
        path = source_cache / entry["filename"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"Source archive changed: {path.name}")
        archives.append(path)
    output.mkdir(parents=True, exist_ok=True)
    result = output / f"PerformanceDashboard-{version}-windows-sources.tar.gz"
    if result.exists():
        raise ValueError(f"Source output already exists: {result}")
    with tarfile.open(result, "w:gz") as archive:
        for path in archives:
            archive.add(path, arcname="sources/" + path.name)
        archive.add(source_cache / "sources.json", arcname="sources/sources.json")
        archive.add(ROOT / "dist/stage/metadata/windows-runtime-inventory.json", arcname="sources/windows-runtime-inventory.json")
    print(result)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/ci/windows")
    parser.add_argument("--source-cache", type=Path, default=ROOT / "out/windows-sources")
    parser.add_argument("--toolchain-source", type=Path, default=ROOT / "out/gnustep-cli-new")
    parser.add_argument("--theme", type=Path, default=ROOT / "out/WinUITheme")
    parser.add_argument("--packager", type=Path, default=ROOT / "out/gnustep-packager")
    args = parser.parse_args()
    collect(args.version, args.output, args.source_cache, args.toolchain_source, args.theme, args.packager)
