#!/usr/bin/env python3
"""Retain authenticated Windows inputs alongside the packager's provenance."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def record(version):
    path = ROOT / f"dist/packages/PerformanceDashboard-{version}-win64.provenance.json"
    result = json.loads(path.read_text(encoding="utf-8-sig"))
    inputs = json.loads((ROOT / "packaging/release-inputs.json").read_text())
    runtime = ROOT / "dist/stage/metadata/windows-runtime-inventory.json"
    result["inputs"] = {name: inputs[name] for name in ("gnustep-toolchain-windows", "gnustep-packager")}
    result["inputs"]["windowsRuntimeSources"] = {
        "lockFile": "packaging/windows-runtime-sources.json",
        "sha256": hashlib.sha256((ROOT / "packaging/windows-runtime-sources.json").read_bytes()).hexdigest()}
    result["runtimeInventory"] = {"path": "metadata/windows-runtime-inventory.json",
                                  "sha256": hashlib.sha256(runtime.read_bytes()).hexdigest()}
    result["checks"] = {"authenticatedToolchain": "passed", "runtimeOwnershipAndLicenses": "passed",
                        "msiInstallLaunchUninstall": "passed on producer host",
                        "cleanClientAcceptance": "not performed", "realGuiWorkloads": "separate acceptance gate"}
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    record(parser.parse_args().version)
