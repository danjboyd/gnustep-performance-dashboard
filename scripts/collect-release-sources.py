#!/usr/bin/env python3
"""Collect matching project, GNUstep and bundled Debian library source.

Run in the Debian release builder after staging, with deb-src enabled. The
archive accompanies the AppImage; upstream notices remain in each source.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[1]
BUILDER = "4d5504bbedf076f824c952f4ab198d09547c8c3c"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("csd_source_check", root / "scripts/check-csd-package.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args], text=True).strip()


def select_custom(args):
    marker = root / "dist/stage/metadata/custom-toolchain-lock.json"
    requested = any((args.custom_lock, args.sdk_provenance, args.builder_source))
    if not requested:
        if marker.exists() or os.environ.get("PD_CSD_TOOLCHAIN_LOCK"):
            raise ValueError("Custom candidate refuses default home-directory source lock; "
                             "pass --custom-lock, --sdk-provenance and --builder-source")
        return None
    if not all((args.custom_lock, args.sdk_provenance, args.builder_source)):
        raise ValueError("Custom mode requires lock, SDK provenance and builder source")
    check.require(not git(root, "status", "--porcelain"), "custom source requires a clean application checkout")
    lock_path = args.custom_lock.resolve(strict=True)
    lock = json.loads(lock_path.read_text())
    review_path = check.inside(lock_path.parent, lock_path.parent / lock["pd_review"]["review_inputs"])
    reviewed = check.check_review_inputs(review_path)
    check.require(reviewed["lockSHA256"] == check.digest(lock_path), "review lock mismatch")
    if marker.exists():
        check.verified_digest(marker, check.digest(lock_path), "staged custom lock")
        check.verified_digest(marker.with_name("custom-toolchain-provenance.json"),
                              check.digest(args.sdk_provenance), "staged SDK provenance")
    provenance = json.loads(args.sdk_provenance.read_text())
    check.require(provenance.get("schema_version") == 1
                  and provenance.get("kind") == "custom-gnustep-toolchain-provenance"
                  and provenance.get("official") is False
                  and provenance.get("install_domain") == "LOCAL", "custom SDK provenance format mismatch")
    check.require(provenance.get("lock", {}).get("sha256") == check.digest(lock_path), "SDK lock mismatch")
    actual = provenance.get("components", [])
    check.require(len(actual) == len(lock["components"]), "SDK component count mismatch")
    for expected, recorded in zip(lock["components"], actual):
        check.require(recorded.get("name") == expected["name"]
                      and recorded.get("url") == expected["url"]
                      and recorded.get("revision") == expected["revision"]
                      and recorded.get("resolved_commit") == expected["revision"]
                      and recorded.get("configure_args", []) == expected.get("configure_args", [])
                      and recorded.get("applied_patches", []) == expected.get("patches", []),
                      "SDK revision/patch/configuration mismatch: " + expected["name"])
    check.require(lock["pd_review"].get("builder_inspection_revision") == BUILDER
                  and git(args.builder_source, "rev-parse", "HEAD") == BUILDER
                  and not git(args.builder_source, "status", "--porcelain"), "builder identity/cleanliness mismatch")
    return dict(lock=lock, lock_path=lock_path, review_path=review_path,
                review=json.loads(review_path.read_text()), provenance_path=args.sdk_provenance)


def copy_custom(custom, work):
    destination = work / "custom-sdk"
    destination.mkdir()
    lock_path = custom["lock_path"]
    shutil.copy2(lock_path, destination / lock_path.name)
    review_path = custom["review_path"]
    shutil.copy2(review_path, destination / review_path.name)
    shutil.copy2(custom["provenance_path"], destination / "gnustep-toolchain-provenance.json")
    review = custom["review"]
    policy = review["backendNeededPolicy"]["path"]
    shutil.copy2(lock_path.parent / policy, destination / policy)
    for patch in review["sdkPatchOrder"]:
        target = destination / patch["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(lock_path.parent / patch["path"], target)
    for patch in review["applicationPatches"]:
        for entry in (patch, patch["appliedSource"]):
            target = destination / "application" / entry["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / entry["path"], target)
    (destination / "APPLYING-PATCHES.txt").write_text(
        "Extract each upstream archive at the revision in the custom lock. Apply its patches "
        "with git apply in the listed per-component order (16 total), from this directory. "
        "Use the lock configure_args and the archived gnustep-cli-new custom builder at " + BUILDER + ".\n"
        "The CSD application patch is already applied in PerformanceDashboard.tar; do not apply it twice. "
        "The review manifest binds its patch and applied-source hashes.\n"
        "SDK provenance binds component revisions/configuration/applied patches to the lock. "
        "It has no builder-revision field; the included clean builder checkout identity is the "
        "reviewed lock's builder_inspection_revision, not a new SDK provenance claim.\n")


def collect(args):
    version = args.version
    work = args.work or root / "out" / "corresponding-source"
    output = args.output or root / "dist/ci/linux" / f"PerformanceDashboard-{version}-sources.tar.gz"
    if work.exists() or output.exists():
        raise ValueError("Use fresh source work/output paths; refusing stale output")
    custom = select_custom(args)
    toolchain = Path.home() / ".local/share/gnustep-cli"
    lock = custom["lock"] if custom else json.loads((toolchain / "source-lock.json").read_text())
    work.mkdir(parents=True)
    if custom:
        copy_custom(custom, work)
    inputs = json.loads((root / "packaging/release-inputs.json").read_text())
    fallback = json.loads((root / "packaging/linux/robin-map-source.json").read_text())
    libobjc = next(c for c in lock["components"] if c["name"] == "libobjc2")
    if libobjc["revision"] != fallback["upstreamBuildDescription"]["libobjc2Revision"]:
        raise ValueError("libobjc2 changed; audit its fallback source before collecting")
    records = []

    for component in lock["components"] + [dict(inputs["adwaita"], name="adwaita"),
            dict(inputs["gnustep-packager"], name="gnustep-packager"),
            dict(name="gnustep-cli-new", url="https://github.com/danjboyd/gnustep-cli-new.git",
                 revision=BUILDER if custom else "e7915a3984f851a4137591899b047f40ee1f7713"),
            dict(name="appimage-runtime", url="https://github.com/AppImage/type2-runtime.git", revision="caf24f9f712084686bfc24a70b75e50df0aefb9c"),
            fallback]:
        repository = component["url"].removesuffix(".git").removeprefix("https://github.com/")
        revision = component["revision"]
        url = component.get("archiveURL") or f"https://codeload.github.com/{repository}/tar.gz/{revision}"
        path = work / f"{component['name']}-{revision}.tar.gz"
        if custom and component["name"] == "gnustep-cli-new":
            git(args.builder_source, "archive", "--format=tar.gz", "-o", str(path.resolve()), BUILDER)
        elif not path.exists():
            with urllib.request.urlopen(url) as source, path.open("wb") as dest:
                shutil.copyfileobj(source, dest)
        expected = component.get("archiveSHA256")
        if expected and hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("Corresponding source archive digest mismatch: " + path.name)
        record = dict(name=component["name"], revision=revision, url=url)
        if expected:
            record.update(tag=component["tag"], sha256=expected)
        records.append(record)
        print("Collected", path.name, flush=True)

    debian = work / "debian"
    debian.mkdir(exist_ok=True)
    packages = {line.split("\t")[1].strip() for line in
                (root / "dist/stage/metadata/licenses/host-libraries.txt").read_text().splitlines()
                if "\t" in line}
    sources = set()
    for package in sorted(packages):
        name, revision = subprocess.check_output(["dpkg-query", "-W",
            "-f=${source:Package}\t${source:Version}", package], text=True).split("\t")
        sources.add((name, revision))
    for name, revision in sorted(sources):
        subprocess.run(["apt-get", "source", "--download-only", f"{name}={revision}"], cwd=debian, check=True)
        records.append(dict(name=name, revision=revision, distribution="Debian"))

    subprocess.run(["git", "archive", "--format=tar", "--prefix=PerformanceDashboard/",
                    "-o", str(work / "PerformanceDashboard.tar"), "HEAD"], cwd=root, check=True)
    for name in (() if custom else ("source-lock.json", "component-inventory.json", "toolchain-manifest.json", "toolchain-assembly.json")):
        if (toolchain / name).exists():
            shutil.copy2(toolchain / name, work / name)
    (work / "README.txt").write_text(("Custom SDK: use custom-sdk/APPLYING-PATCHES.txt and its lock/provenance.\n" if custom else "") + """Corresponding source for Performance Dashboard's AppImage

    PerformanceDashboard.tar contains the application, framework, agent, vendored
    updater, build/staging scripts, licenses and libs-back patches. Extract it and
    see docs/release.md and packaging/linux/libs-back for the build instructions.
    GNUstep sources match the included lock (custom-sdk/*lock*.json in custom mode,
    source-lock.json otherwise); gnustep-cli-new contains the toolchain build recipes.
    Debian .dsc/orig/debian archives are the sources for
    the distribution libraries copied into the AppImage (dpkg-source -x FILE.dsc).
    See the adjacent binary provenance for compiler and installed package versions.
    Dependency licenses and copyright notices are preserved in their archives.
    """)
    (work / "sources.json").write_text(json.dumps(records, indent=2) + "\n")
    (work / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(work)}\n"
        for p in sorted(work.rglob("*")) if p.is_file() and p.name != "SHA256SUMS"))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "x:gz") as archive:
        archive.add(work, arcname=f"PerformanceDashboard-{version}-sources")
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    for name in ("custom-lock", "sdk-provenance", "builder-source", "work", "output"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    try:
        collect(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, "Corresponding source FAILED: " + str(error) + "\n")


if __name__ == "__main__":
    main()
