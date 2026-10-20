#!/usr/bin/env python3
"""Map staged runtime files to exact pacman-owned bytes and bundle licenses.

Run before and after theme provisioning. Generated GNUstep.conf and application
outputs are identified separately. This is an ownership inventory, not a claim
that corresponding sources or clean-client acceptance are complete.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fields(path):
    result = {}
    for block in path.read_text(encoding="utf-8").strip().split("\n\n"):
        lines = block.splitlines()
        if lines and lines[0].startswith("%"):
            result[lines[0].strip("%")] = lines[1:]
    return result


def inventory(stage, toolchain, project, source_cache=None):
    candidates, packages = {}, {}
    database = toolchain / "var/lib/pacman/local"
    if not database.is_dir():
        raise ValueError("Toolchain has no pacman ownership database")
    for directory in sorted(database.iterdir()):
        if not (directory / "desc").is_file():
            continue
        package = fields(directory / "desc")
        name = package["NAME"][0]
        paths = fields(directory / "files").get("FILES", [])
        packages[name] = {"name": name, "version": package["VERSION"][0],
                          "licenses": package.get("LICENSE", []), "paths": paths}
        for relative in paths:
            if relative.endswith("/"):
                continue
            candidates.setdefault(Path(relative).name.lower(), []).append((name, relative))

    own = {"runtime/bin/gstrace.exe": project / "Tools/gstrace/obj/gstrace.exe",
           "runtime/bin/gsperf-agent.dll": project / "Runtime/obj/gsperf-agent.dll"}
    for path in (project / "GSPerformance/obj").glob("*.dll"):
        own["runtime/bin/" + path.name] = path
    theme_bundle = project / "dist/tmp/theme-inputs/sources/WinUITheme/WinUITheme.theme"
    if (stage / "runtime/lib/GNUstep/Themes/WinUITheme.theme").exists():
        theme_source = theme_bundle.parent
        expected = json.loads((project / "packaging/package.manifest.json").read_text())["platformOverrides"]["windows"]["themeInputs"][0]["ref"]
        actual = subprocess.check_output(["git", "-C", str(theme_source), "rev-parse", "HEAD"], text=True).strip()
        if actual != expected or subprocess.check_output(["git", "-C", str(theme_source), "status", "--porcelain"], text=True).strip():
            raise ValueError("Provisioned theme source differs from its clean pin")
        for path in theme_bundle.rglob("*"):
            if path.is_file():
                own["runtime/lib/GNUstep/Themes/WinUITheme.theme/" + path.relative_to(theme_bundle).as_posix()] = path
    files, selected = [], set()
    for path in sorted((stage / "runtime").rglob("*")):
        if not path.is_file():
            continue
        relative, sha = path.relative_to(stage).as_posix(), digest(path)
        if relative == "runtime/bin/GNUstep.conf":
            files.append({"path": relative, "sha256": sha, "owner": "generated GNUstep configuration"})
            continue
        if relative in own and own[relative].is_file() and digest(own[relative]) == sha:
            owner = "WinUITheme" if relative.startswith("runtime/lib/GNUstep/Themes/") else "Performance Dashboard"
            files.append({"path": relative, "sha256": sha, "owner": owner})
            continue
        matches = [(name, source) for name, source in candidates.get(path.name.lower(), [])
                   if (toolchain / source).is_file() and digest(toolchain / source) == sha]
        if not matches:
            raise ValueError(f"No byte-identical package-owned source for {relative}")
        owners = sorted({name for name, _ in matches})
        selected.update(owners)
        files.append({"path": relative, "sha256": sha, "owners": owners,
                      "toolchainPaths": sorted({source for _, source in matches})})

    notices = stage / "metadata/licenses/msys2"
    notices.mkdir(parents=True, exist_ok=True)
    result, missing = [], []
    for name in sorted(selected):
        package = dict(packages[name])
        paths = package.pop("paths")
        licenses = []
        for relative in paths:
            if not ("/share/licenses/" in relative or Path(relative).name.lower() in
                    ("license", "license.txt", "copying", "copying.lib", "copyright")) or not (toolchain / relative).is_file():
                continue
            destination = notices / name / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(toolchain / relative, destination)
            licenses.append({"path": destination.relative_to(stage).as_posix(),
                             "sha256": digest(destination), "toolchainPath": relative})
        # Preserve all source notices too: a GNUstep package can contain tools
        # under a different license from its shared library.
        if source_cache and source_cache.is_dir():
            for receipt in sorted(source_cache.glob("*.src.tar.zst.json")):
                source = json.loads(receipt.read_text(encoding="utf-8"))
                if name not in source["binaryPackages"]:
                    continue
                if any("sha256" not in entry for entry in source["extractedLicenses"]):
                    continue  # Older exploratory receipts must be regenerated.
                archive = source_cache / source["filename"]
                if digest(archive) != source["sha256"]:
                    raise ValueError(f"Source archive changed: {archive.name}")
                for entry in source["extractedLicenses"]:
                    original = source_cache / "licenses" / source["base"] / entry["file"]
                    if digest(original) != entry["sha256"]:
                        raise ValueError(f"Extracted source license changed: {original}")
                    destination = notices / name / "source" / original.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(original, destination)
                    licenses.append({"path": destination.relative_to(stage).as_posix(),
                                     "sha256": digest(destination), "sourceArchive": archive.name,
                                     "sourceArchiveSha256": source["sha256"],
                                     "archiveMember": entry["archiveMember"]})
        package["licenseFiles"] = licenses
        if not licenses:
            missing.append(name)
        result.append(package)
    report = {"schemaVersion": 1, "scope": "staged runtime, including provisioned theme when present",
              "files": files, "packages": result, "missingLicenseTexts": missing,
              "correspondingSources": "not assessed"}
    metadata = stage / "metadata"
    metadata.mkdir(parents=True, exist_ok=True)
    (metadata / "windows-runtime-inventory.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["MSYS2 runtime owners; exact file mappings and hashes: ../windows-runtime-inventory.json",
             "License texts copied from the selected toolchain's package-owned files.", ""]
    lines += [f"{p['name']} {p['version']}: {', '.join(p['licenses'])}" for p in result]
    if missing:
        lines += ["", "MISSING LICENSE TEXTS: " + ", ".join(missing)]
    (metadata / "licenses/msys2-libraries.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-cache", type=Path, default=Path(__file__).resolve().parents[1] / "out/windows-sources")
    parser.add_argument("--allow-missing-license-texts", action="store_true",
                        help="Inventory-only first pass before corresponding sources are acquired")
    args = parser.parse_args()
    report = inventory(args.stage.resolve(), args.toolchain.resolve(), args.project.resolve(), args.source_cache.resolve())
    print(f"Mapped {len(report['files'])} runtime files to {len(report['packages'])} packages")
    if report["missingLicenseTexts"] and not args.allow_missing_license_texts:
        raise SystemExit("Missing package license texts: " + ", ".join(report["missingLicenseTexts"]))
