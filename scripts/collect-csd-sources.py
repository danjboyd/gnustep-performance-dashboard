#!/usr/bin/env python3
"""Compatibility CLI: one acquisition core, plus independent source verification."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
from types import SimpleNamespace

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

verifier = module('csd_verifier', 'verify-csd-sources.py')
verify_bundle = verifier.verify_bundle


def collect(root, version, output, sdk):
    core = module('source_core', 'collect-release-sources.py')
    core.root = root
    work = root / 'out/csd-ci'
    archive = output / ('PerformanceDashboard-' + version + '-sources.tar.gz')
    core.collect(SimpleNamespace(version=version, custom_lock=root / 'packaging/linux/v017-custom-toolchain.lock.proposed.json',
        sdk_provenance=sdk / 'gnustep-toolchain-provenance.json', builder_source=work / 'builder',
        work=work / 'corresponding-source', output=archive, ci_evidence=work))
    return verifier.verify_bundle(archive, subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
        verifier.policy.sha(root / 'packaging/linux/v017-custom-toolchain.lock.proposed.json'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--receipt-output', type=Path)
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--commit')
    parser.add_argument('--lock-sha256')
    args = parser.parse_args()
    try:
        if args.verify:
            result = verify_bundle(args.verify, args.commit, args.lock_sha256)
        else:
            sdk = Path(os.environ['GNUSTEP_CLI_ROOT']).resolve(strict=True)
            result = collect(ROOT, args.version, args.output, sdk)
        if args.receipt_output:
            with args.receipt_output.open('x') as receipt:
                receipt.write(json.dumps(result, indent=2) + '\n')
    except (OSError, ValueError, KeyError, TypeError, AttributeError, tarfile.TarError, EOFError, subprocess.SubprocessError) as error:
        parser.exit(1, 'CSD corresponding source failed: ' + str(error) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    raise SystemExit(main())
