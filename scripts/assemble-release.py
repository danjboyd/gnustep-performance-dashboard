#!/usr/bin/env python3
"""Validate and assemble release artifacts without publishing anything.

Each requested backend must have one feed, its binary and provenance, plus
corresponding sources. Mixed commits, dirty builds, mismatched payload hashes,
duplicate names with different bytes, and wrong-channel feeds fail closed.
The destination must not already exist.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import tempfile
import tarfile
from urllib.parse import quote


REPOSITORY = "https://github.com/danjboyd/gnustep-performance-dashboard"
PAGES = "https://danjboyd.github.io/gnustep-performance-dashboard"
PLATFORMS = {"appimage": "linux", "msi": "windows"}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_sources(path, commit):
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            if member.isfile() and member.name.endswith("/PerformanceDashboard.tar"):
                with tarfile.open(fileobj=io.BytesIO(archive.extractfile(member).read())) as source:
                    require(source.pax_headers.get("comment") == commit,
                            f"Corresponding sources name another commit: {path.name}")
                return
    raise ValueError(f"Corresponding sources have no git application archive: {path.name}")


def assemble(inputs, output, version, commit, backends):
    require(re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version), "Invalid release version")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "A full source commit is required")
    require(not output.exists(), f"Output already exists: {output}")
    channel = "prerelease" if "-" in version else "stable"
    files = {}
    for directory in inputs:
        require(directory.is_dir(), f"Missing input directory: {directory}")
        for path in directory.iterdir():
            # Ignore derived checksums and site copies from previous assembly.
            if not path.is_file() or path.name in ("SHA256SUMS", "assembly.json"):
                continue
            require(not path.is_symlink(), f"Input must be a regular file: {path}")
            if path.name in files:
                require(digest(path) == digest(files[path.name]), f"Conflicting artifact name: {path.name}")
            else:
                files[path.name] = path
    require(files, "No artifacts supplied")

    def check_payload(asset, downloadable=True):
        name = asset.get("name", "")
        require(name in files, f"Missing payload: {name}")
        path = files[name]
        require(asset.get("sha256") == digest(path), f"Payload digest mismatch: {name}")
        require(asset.get("sizeBytes") == path.stat().st_size, f"Payload size mismatch: {name}")
        if downloadable:
            expected = f"{REPOSITORY}/releases/download/v{version}/{quote(name)}"
            require(asset.get("url") == expected, f"Wrong release download URL: {name}")
        return name

    feeds = {}
    checked = set()
    for name, path in files.items():
        if not name.endswith(".update-feed.json"):
            continue
        feed = load(path)
        require(feed.get("formatVersion") == 1, f"Unsupported feed format: {name}")
        require(feed.get("provider") == "github-release-feed", f"Unsupported feed provider: {name}")
        require(feed.get("channel") == channel, f"Wrong update channel: {name}")
        require(feed.get("package", {}).get("version") == version, f"Wrong package version: {name}")
        releases = feed.get("releases", [])
        require(len(releases) == 1, f"Expected exactly one release: {name}")
        release = releases[0]
        require(release.get("version") == version and release.get("tag") == "v" + version,
                f"Wrong release identity: {name}")
        assets = release.get("assets", [])
        require(len(assets) == 1, f"Expected one backend payload per feed: {name}")
        asset = assets[0]
        backend = asset.get("backend")
        require(backend in backends, f"Unexpected backend: {backend}")
        require(backend not in feeds, f"Duplicate backend feed: {backend}")
        platform = PLATFORMS[backend]
        require(asset.get("platform") == platform + "-x64", f"Wrong platform: {name}")
        require(feed.get("feedUrl") == f"{PAGES}/updates/{platform}/{channel}.json", f"Wrong feed URL: {name}")
        binary = check_payload(asset)
        checked.add(binary)
        expected_suffix = ".AppImage" if backend == "appimage" else ".msi"
        require(binary.endswith(expected_suffix), f"Wrong binary extension: {binary}")
        provenance_name = binary[:-len(expected_suffix)] + ".provenance.json"
        require(provenance_name in files, f"Missing provenance: {provenance_name}")
        provenance = load(files[provenance_name])
        if backend == "appimage":
            require(provenance.get("version") == version, "Wrong Linux provenance version")
            require(provenance.get("commit") == commit and provenance.get("sourceDirty") is False,
                    "Linux provenance must name the clean release commit")
            require("zsync" in asset, "AppImage feed has no zsync payload")
            checked.add(check_payload(asset["zsync"]))
            source_name = f"PerformanceDashboard-{version}-sources.tar.gz"
        else:
            require(provenance.get("package", {}).get("version") == version, "Wrong Windows provenance version")
            source = provenance.get("source") or {}
            require(source.get("commit") == commit and source.get("dirty") is False,
                    "Windows provenance must name the clean release commit")
            require(check_payload(provenance.get("artifact", {}), False) == binary,
                    "Windows provenance names a different MSI")
            related = provenance.get("relatedArtifacts", [])
            require(any(a.get("name", "").endswith("-portable.zip") for a in related),
                    "Windows provenance has no portable ZIP")
            for related_asset in related:
                checked.add(check_payload(related_asset, False))
            source_name = f"PerformanceDashboard-{version}-windows-sources.tar.gz"
        require(source_name in files and files[source_name].stat().st_size > 0,
                f"Missing corresponding-source archive: {source_name}")
        check_sources(files[source_name], commit)
        feeds[backend] = feed
    require(set(feeds) == set(backends), "A required backend feed is missing")
    # Never silently include an unrelated/stale binary from a reused output directory.
    for name in files:
        if name.endswith((".AppImage", ".AppImage.zsync", ".msi", "-portable.zip")):
            require(name in checked, f"Unreferenced binary artifact: {name}")

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".release-assembly-", dir=output.parent))
    try:
        for name, path in files.items():
            shutil.copy2(path, staging / name)
        for backend, feed in feeds.items():
            directory = staging / "site" / "updates" / PLATFORMS[backend]
            directory.mkdir(parents=True)
            (directory / f"{channel}.json").write_text(json.dumps(feed, indent=2) + "\n", encoding="utf-8")
        receipt = {"version": version, "commit": commit, "channel": channel,
                   "backends": sorted(feeds), "validatedPayloads": sorted(checked),
                   "publication": "not performed", "acceptance": "separate release gate"}
        (staging / "assembly.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        (staging / "SHA256SUMS").write_text("".join(
            f"{digest(path)}  {path.name}\n" for path in sorted(staging.iterdir()) if path.is_file()), encoding="utf-8")
        staging.rename(output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    print(f"Assembled {version} ({', '.join(sorted(feeds))}) in {output}; nothing published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--require-backend", choices=PLATFORMS, action="append", required=True)
    args = parser.parse_args()
    assemble(args.input, args.output, args.version, args.commit, args.require_backend)


if __name__ == "__main__":
    main()
