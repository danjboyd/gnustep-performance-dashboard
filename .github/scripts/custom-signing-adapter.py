#!/usr/bin/env python3
"""Adapt verified custom provenance using the exact AppImage's public config.

No private input is read. Original producer bytes are kept separately.
"""
import argparse
import base64
import copy
import importlib.util
import json
import mmap
import os
from pathlib import Path
import shutil
import subprocess
import struct
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('unsigned_final', Path(__file__).with_name('csd-review-final.py'))
final = importlib.util.module_from_spec(spec)
spec.loader.exec_module(final)
require = final.require
PACKAGE = 'io.github.danjboyd.PerformanceDashboard'


def squashfs_offset(app):
    """Locate a bounded SquashFS v4 header without running unsigned code."""
    with app.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        require(data[:6] == b'\x7fELF\x02\x01' and data[8:11] == b'AI\x02', 'type2 x86_64 AppImage required')
        offsets = []
        cursor = 0
        while True:
            cursor = data.find(b'hsqs', cursor)
            if cursor < 0:
                break
            if cursor + 96 <= len(data):
                block_size = struct.unpack_from('<I', data, cursor + 12)[0]
                major, minor = struct.unpack_from('<HH', data, cursor + 28)
                used = struct.unpack_from('<Q', data, cursor + 40)[0]
                if major == 4 and minor == 0 and 4096 <= block_size <= 1048576 and not block_size & (block_size - 1) and 96 <= used <= len(data) - cursor:
                    offsets.append(cursor)
            cursor += 4
        require(len(offsets) == 1, 'one bounded SquashFS payload required')
        return offsets[0]


def extract_payload(app, extracted):
    offset = squashfs_offset(app)
    extracted.mkdir(parents=True)
    subprocess.run(['unsquashfs', '-no-progress', '-no-xattrs', '-processors', '2', '-offset', str(offset),
                    '-dest', str(extracted / 'squashfs-root'), str(app.resolve())], check=True, stdout=subprocess.DEVNULL)


def prepare(root, inputs, output, evidence, extracted, request, public, version):
    require(not any(path.exists() for path in (output, evidence, extracted)), 'signing outputs must be fresh')
    require(len(base64.b64decode(public, validate=True)) == 32, 'valid public trust anchor required')
    spec = importlib.util.spec_from_file_location('production_selection', root / '.github/scripts/release-selection.py')
    selection = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(selection)
    selection.custom_version(root / 'packaging/package.manifest.json', root / 'packaging/linux/release-production.json',
                             'production', version)
    receipt_sha = final.verify_receipt(root, inputs, version)
    receipt = final.policy.load(inputs / final.RECEIPT)
    require(receipt['applicationCommit'] == request['commit'] and receipt['version'] == version, 'request/producer receipt mismatch')
    base = 'PerformanceDashboard-' + version + '-x86_64'
    names = [base + suffix for suffix in ('.AppImage', '.AppImage.zsync', '.provenance.json', '.update-feed.json')]
    names.append('PerformanceDashboard-' + version + '-sources.tar.gz')
    for name in names:
        require(final.file_record(inputs / name) == receipt['files'][name], 'producer bytes changed: ' + name)
    provenance_path = inputs / (base + '.provenance.json')
    original_bytes = provenance_path.read_bytes()
    original_sha = final.policy.sha(provenance_path)
    provenance = final.policy.load(provenance_path)
    require(provenance.get('kind') == 'performance-dashboard-custom-csd-review-provenance'
            and provenance.get('officialToolchain') is False and provenance.get('sourceDirty') is False
            and provenance.get('commit') == request['commit'] and provenance.get('version') == version,
            'custom provenance identity mismatch')
    app = inputs / (base + '.AppImage')
    extract_payload(app, extracted)
    require(final.file_record(app) == receipt['files'][app.name], 'AppImage changed during extraction')
    payload = extracted / 'squashfs-root/usr'
    final.payload_ties(payload, provenance)
    configs = list((extracted / 'squashfs-root').rglob('gnustep-packager-update.json'))
    expected_config = payload / 'metadata/updates/gnustep-packager-update.json'
    require(configs == [expected_config] and not expected_config.is_symlink(), 'one exact extracted updater config required')
    require(expected_config.resolve().is_relative_to(payload.resolve()), 'updater config escapes payload')
    config = json.loads(expected_config.read_text(encoding='utf-8-sig'))
    require(config.get('package', {}).get('id') == PACKAGE and config['package'].get('version') == version
            and config['package'].get('backend') == 'appimage' and config['package'].get('platform') == 'linux-x64',
            'extracted updater package identity mismatch')
    require(config.get('updates', {}).get('publicEDKey') == public, 'extracted public anchor mismatch')
    manifest_key = final.policy.load(root / 'packaging/package.manifest.json').get('updates', {}).get('publicEDKey')
    require(manifest_key in (None, public), 'source public anchor mismatch')
    for field, value in (('updatesPackageIdentifier', PACKAGE), ('updatesPublicEDKey', public)):
        require(provenance.get(field, value) == value, 'conflicting existing signing field')
    adapted = copy.deepcopy(provenance)
    adapted.update(updatesPackageIdentifier=PACKAGE, updatesPublicEDKey=public)
    adapted['signingAdapter'] = dict(originalProvenanceSHA256=original_sha,
        producerReceiptSHA256=receipt_sha, extractedUpdaterConfigSHA256=final.policy.sha(expected_config),
        appImageSHA256=final.policy.sha(app), producer=request)
    output.mkdir(parents=True)
    evidence.mkdir(parents=True)
    for name in names:
        shutil.copy2(inputs / name, output / name)
    (output / provenance_path.name).write_text(json.dumps(adapted, indent=2) + '\n')
    (evidence / 'original-provenance.json').write_bytes(original_bytes)
    adapter = dict(schemaVersion=1, kind='custom-csd-signing-adapter', version=version, commit=request['commit'],
                   **adapted['signingAdapter'], adaptedProvenanceSHA256=final.policy.sha(output / provenance_path.name))
    (evidence / 'provenance-adapter.json').write_text(json.dumps(adapter, indent=2) + '\n')
    require(provenance_path.read_bytes() == original_bytes, 'original producer provenance changed')
    return adapter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('input', 'output', 'evidence', 'extracted', 'request'):
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    try:
        prepare(ROOT, args.input, args.output, args.evidence, args.extracted,
                json.loads(args.request.read_text()), os.environ.get('UPDATE_ED_PUBLIC_KEY', ''), args.version)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, 'Custom provenance adapter refused: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
