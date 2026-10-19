#!/usr/bin/env python3
"""Collect matching project, GNUstep and bundled Debian library source.

Run in the Debian release builder after staging, with deb-src enabled. The
archive accompanies the AppImage; upstream notices remain in each source.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[1]
version = sys.argv[1]
work = root / "out" / "corresponding-source"
work.mkdir(parents=True, exist_ok=True)
toolchain = Path.home() / ".local/share/gnustep-cli"
lock = json.loads((toolchain / "source-lock.json").read_text())
inputs = json.loads((root / "packaging/release-inputs.json").read_text())
records = []

for component in lock["components"] + [dict(inputs["adwaita"], name="adwaita"),
        dict(inputs["gnustep-packager"], name="gnustep-packager"),
        dict(name="gnustep-cli-new", url="https://github.com/danjboyd/gnustep-cli-new.git",
             revision="e7915a3984f851a4137591899b047f40ee1f7713"),
        dict(name="appimage-runtime", url="https://github.com/AppImage/type2-runtime.git", revision="caf24f9f712084686bfc24a70b75e50df0aefb9c"),
        dict(name="robin-map-fallback", url="https://github.com/Tessil/robin-map.git", revision="v1.2.1")]:
    repository = component["url"].removesuffix(".git").removeprefix("https://github.com/")
    revision = component["revision"]
    url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
    path = work / f"{component['name']}-{revision}.tar.gz"
    if not path.exists():
        with urllib.request.urlopen(url) as source, path.open("wb") as dest:
            shutil.copyfileobj(source, dest)
    records.append(dict(name=component["name"], revision=revision, url=url))
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
for name in ("source-lock.json", "component-inventory.json", "toolchain-manifest.json", "toolchain-assembly.json"):
    if (toolchain / name).exists():
        shutil.copy2(toolchain / name, work / name)
(work / "README.txt").write_text("""Corresponding source for Performance Dashboard's AppImage

PerformanceDashboard.tar contains the application, framework, agent, vendored
updater, build/staging scripts, licenses and libs-back patches. Extract it and
see docs/release.md and packaging/linux/libs-back for the build instructions.
The GNUstep sources match source-lock.json; gnustep-cli-new contains the
toolchain build recipes. Debian .dsc/orig/debian archives are the sources for
the distribution libraries copied into the AppImage (dpkg-source -x FILE.dsc).
See the adjacent binary provenance for compiler and installed package versions.
Dependency licenses and copyright notices are preserved in their archives.
""")
(work / "sources.json").write_text(json.dumps(records, indent=2) + "\n")
(work / "SHA256SUMS").write_text("".join(
    f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(work)}\n"
    for p in sorted(work.rglob("*")) if p.is_file() and p.name != "SHA256SUMS"))
output = root / "dist/ci/linux" / f"PerformanceDashboard-{version}-sources.tar.gz"
output.parent.mkdir(parents=True, exist_ok=True)
with tarfile.open(output, "w:gz") as archive:
    archive.add(work, arcname=f"PerformanceDashboard-{version}-sources")
print(output)
