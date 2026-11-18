#!/usr/bin/env python3
"""Write custom CSD review-package provenance from verified inputs and payload.

This path never reads the managed SDK/backend release recipe. No inspected ELF
is executed. Build IDs tie selected payloads to pre-strip SDK/theme identities;
final hashes are recorded separately. Runtime qualification remains separate.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("csd_package_check", Path(__file__).with_name("check-csd-package.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
spec = importlib.util.spec_from_file_location("trellis_package", Path(__file__).with_name("trellis-package.py"))
trellis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trellis)


def identity(path):
    path = Path(path)
    result = subprocess.run(["readelf", "-n", str(path)], check=True, text=True, capture_output=True, timeout=10)
    match = re.search(r"Build ID:\s*([0-9a-fA-F]+)", result.stdout)
    check.require(match is not None, "missing ELF build ID: " + str(path))
    return {"sha256": check.digest(path), "buildId": match.group(1).lower()}


def bound_json(payload, relative, source):
    path = check.inside(payload, payload / relative)
    check.require(check.digest(path) == check.digest(source), "embedded input differs: " + relative)
    return json.loads(path.read_text())


def make_record(args):
    # Same strict identity gate as staging, repeated before writing a sidecar.
    input_result = check.check_inputs(args)
    payload = Path(args.payload).resolve(strict=True)
    capabilities = check.check_staged(payload)
    trellis_record = trellis.verify(payload)
    sdk = Path(args.sdk).resolve(strict=True)
    lock = bound_json(payload, "metadata/custom-toolchain-lock.json", args.lock)
    sdk_record = bound_json(payload, "metadata/custom-toolchain-provenance.json",
                            sdk / "gnustep-toolchain-provenance.json")
    theme_record = bound_json(payload, "metadata/adwaita-build-receipt.json", args.theme_receipt)
    check.require(bool(re.fullmatch(r"[0-9a-f]{40}", args.commit)), "source commit must be exact")
    check.require(bool(re.fullmatch(r"[0-9a-f]{40}", args.packager_commit)), "packager commit must be exact")
    check.require(bool(re.fullmatch(r"[0-9a-f]{64}", args.source_diff_sha256)), "source diff SHA required")
    pairings = {
        "libs-back": (check.BACK, check.STAGED_BACK),
        "libs-gui": ("Local/Library/Libraries/libgnustep-gui.so.0.32", check.GUI),
        "libs-base": ("Local/Library/Libraries/libgnustep-base.so.1.31", "runtime/lib/libgnustep-base.so.1.31"),
        "libobjc2": ("lib/libobjc.so.4.6", "runtime/lib/libobjc.so.4.6"),
        "libdispatch": ("lib/libdispatch.so", "runtime/lib/libdispatch.so"),
    }
    ties = {}
    for name, (source_relative, staged_relative) in pairings.items():
        source = check.inside(sdk, sdk / source_relative)
        staged = check.inside(payload, payload / staged_relative)
        original = identity(source)
        resolved_relative = str(source.relative_to(sdk))
        recorded = sdk_record.get("elf_files", {}).get(resolved_relative, {})
        check.require(recorded.get("sha256") == original["sha256"]
                      and recorded.get("build_id") == original["buildId"],
                      "SDK ELF differs from recorded provenance: " + name)
        final = identity(staged)
        check.require(original["buildId"] == final["buildId"], "payload build ID mismatch: " + name)
        ties[name] = {"sourcePath": source_relative, "resolvedSourcePath": resolved_relative, "source": original,
                      "payloadPath": staged_relative, "payload": final,
                      "comparison": "same build ID; pre/post transformation SHA recorded"}
    theme_source = identity(Path(args.theme) / "Adwaita")
    theme_final = identity(check.inside(payload, payload / "runtime/System/Library/Themes/Adwaita.theme/Adwaita"))
    check.require(theme_source["sha256"] == theme_record["themeBinarySHA256"]
                  and theme_source["buildId"] == theme_final["buildId"], "payload theme identity mismatch")
    ties["adwaita"] = {"source": theme_source, "payload": theme_final,
                       "comparison": "same build ID; pre/post transformation SHA recorded"}
    ties.update(trellis_record["payloadIdentityChecks"])
    application = {}
    for relative in ("app/PerformanceDashboard.app/PerformanceDashboard",
                     "app/PerformanceDashboard.app/Resources/libgsperf-agent.so",
                     "app/PerformanceDashboard.app/Resources/gsp-launch", "runtime/lib/gsp-launch"):
        application[relative] = identity(check.inside(payload, payload / relative))
    application[trellis.RESOURCE] = {"sha256": trellis_record["resource"]["sha256"]}
    # Construct a fresh whitelist. Never merge in the old managed-recipe JSON.
    return {
        "schemaVersion": 1,
        "kind": "performance-dashboard-custom-csd-review-provenance",
        "package": "PerformanceDashboard", "version": args.version,
        "commit": args.commit, "sourceDirty": args.source_dirty == "true",
        "trackedDiffSha256": args.source_diff_sha256,
        "officialToolchain": False, "qualification": "unsigned review package; runtime results separate",
        "inputs": {
            "customToolchain": {"lockSHA256": input_result["lockSHA256"], "lock": lock,
                                 "sdkProvenanceSHA256": check.digest(sdk / "gnustep-toolchain-provenance.json"),
                                 "sdkProvenance": sdk_record},
            "adwaita": {"sourceRevision": theme_record["themeSourceRevision"], "buildReceipt": theme_record},
            "packager": {"usedCommit": args.packager_commit},
            "trellis": {"source": trellis_record["source"], "buildReceipt": trellis_record["buildReceipt"]},
        },
        "patchSHA256": [{"component": component["name"], "path": patch["path"], "sha256": patch["sha256"]}
                        for component in lock["components"] for patch in component.get("patches", [])],
        "applicationPayload": application,
        "payloadIdentityChecks": ties, "staticCSDCapabilities": capabilities,
        "identityScope": "selected SDK/theme build-ID ties with final hashes; not runtime or visual qualification",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("payload", "lock", "sdk", "backend", "backend-sha256", "theme", "theme-sha256",
                 "theme-receipt", "version", "commit", "packager-commit", "source-diff-sha256", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--source-dirty", choices=("true", "false"), required=True)
    args = parser.parse_args()
    try:
        record = make_record(args)
        output = Path(args.output)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent,
                                         prefix="." + output.name + ".", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            try:
                json.dump(record, temporary, indent=2)
                temporary.write("\n")
            except BaseException:
                temporary_path.unlink(missing_ok=True)
                raise
        try:
            os.replace(temporary_path, output)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("custom CSD provenance FAILED: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
