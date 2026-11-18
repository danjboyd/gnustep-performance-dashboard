#!/usr/bin/env python3
"""Bind the pinned Trellis build to the staged libraries and welcome resource.

Only reads ELF metadata; never executes an inspected library.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LIBRARIES = ('libTrellis.so.0', 'libTrellisEngine.so.0')
RESOURCE = 'app/PerformanceDashboard.app/Resources/WelcomeWindow.trellis'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pin():
    return {key: value for key, value in json.loads((ROOT / 'packaging/release-inputs.json').read_text())
            ['gnustep-trellis'].items() if key != 'comment'}


def identity(path):
    output = subprocess.check_output(['readelf', '-n', str(path)], text=True)
    match = re.search(r'Build ID:\s*([0-9a-fA-F]+)', output)
    require(match is not None, 'Trellis library has no build ID: ' + str(path))
    return dict(sha256=digest(path), buildId=match.group(1).lower())


def make_receipt(source):
    subprocess.run([str(ROOT / 'scripts/pinned-checkout.sh'), '--verify', 'gnustep-trellis', str(source)], check=True)
    return dict(schemaVersion=1, source=pin(), hotReload=False,
                libraries={name: identity(source / 'obj' / name) for name in LIBRARIES})


def verify_source(source):
    recorded = json.loads((source / 'obj/pd-build-receipt.json').read_text())
    require(recorded == make_receipt(source), 'Trellis source build differs from its receipt')
    return recorded


def inside(payload, relative):
    path = (payload / relative).resolve(strict=True)
    require(path.is_relative_to(payload.resolve()), 'Trellis path escapes payload')
    return path


def verify(payload):
    receipt = json.loads(inside(payload, 'metadata/trellis-build-receipt.json').read_text())
    require(receipt.get('schemaVersion') == 1 and receipt.get('source') == pin()
            and receipt.get('hotReload') is False, 'Trellis build receipt source/options differ')
    require(set(receipt['libraries']) == set(LIBRARIES), 'Trellis build library inventory differs')
    ties = {}
    for name in LIBRARIES:
        relative = 'runtime/lib/' + name
        path = inside(payload, relative)
        original = receipt['libraries'][name]
        require(re.fullmatch('[0-9a-f]{64}', original['sha256']) is not None, 'Trellis source hash missing')
        final = identity(path)
        require(final['buildId'] == original['buildId'], 'Trellis payload build ID differs: ' + name)
        ties[name] = dict(source=original, payloadPath=relative, payload=final,
                          comparison='same build ID; pre/post transformation SHA recorded')
    resource = inside(payload, RESOURCE)
    require(digest(resource) == digest(ROOT / 'Dashboard/Resources/WelcomeWindow.trellis'),
            'staged welcome resource differs')
    require(inside(payload, 'metadata/licenses/Trellis.txt').is_file(), 'Trellis license notice missing')
    return dict(source=pin(), buildReceipt=receipt, payloadIdentityChecks=ties,
                resource=dict(path=RESOURCE, sha256=digest(resource)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('receipt', 'source', 'verify'))
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    function = {'receipt': make_receipt, 'source': verify_source, 'verify': verify}[args.command]
    result = function(args.directory)
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
