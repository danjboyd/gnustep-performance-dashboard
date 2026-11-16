#!/usr/bin/env python3
"""Exact unsigned review inventory, final AppImage extraction and read-back receipt.

No downloads, signing, publication, overwrite or fallback to staged payloads.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('csd_state', Path(__file__).with_name('csd-review-state.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
require = policy.require
RECEIPT = 'review-receipt.json'
EVIDENCE = {'container-inputs.json', 'theme-receipt.json', 'backend-closure.json',
            'payload-closure.json', 'pd-csd-cache-receipt.json', 'sources-verification.json'}


def names(version):
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-review(?:\.[0-9]+)?)?', version), 'valid unsigned review or production version required')
    base = 'PerformanceDashboard-' + version + '-x86_64'
    return {base + suffix for suffix in ('.AppImage', '.AppImage.zsync', '.provenance.json', '.update-feed.json', '.metadata.json', '.diagnostics.txt')}


def exact_files(directory, expected):
    require(directory.is_dir(), 'inventory directory missing')
    files = list(directory.iterdir())
    require({p.name for p in files} == expected, 'stale, extra or missing review files')
    require(all(p.is_file() and not p.is_symlink() and p.stat().st_size for p in files),
            'review files must be nonempty regular files, without symlinks')


def canonical(record):
    return json.dumps(record, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n'


def file_record(file):
    return dict(sha256=policy.sha(file), sizeBytes=file.stat().st_size)


def prepare(packages, output, version):
    expected = names(version)
    exact_files(packages, expected)
    output.mkdir(parents=True)  # A stale output is a refusal, never replaced/merged.
    for name in sorted(expected):
        shutil.copy2(packages / name, output / name)


def provenance_ties(provenance):
    ties = dict(provenance['applicationPayload'])
    for item in provenance['payloadIdentityChecks'].values():
        if 'payloadPath' in item:
            ties[item['payloadPath']] = item['payload']
    ties['runtime/System/Library/Themes/Adwaita.theme/Adwaita'] = provenance['payloadIdentityChecks']['adwaita']['payload']
    require(ties, 'final payload identity inventory missing')
    return ties


def payload_ties(payload, provenance):
    ties = provenance_ties(provenance)
    for relative, record in ties.items():
        file = (payload / relative).resolve(strict=True)
        require(file.is_relative_to(payload.resolve()) and file.is_file(), 'final payload identity escapes extraction')
        require(policy.sha(file) == record['sha256'], 'final payload differs from provenance: ' + relative)
    return {name: item['sha256'] for name, item in sorted(ties.items())}


def extract(root, packages, version, extracted):
    exact_files(packages, names(version))
    base = 'PerformanceDashboard-' + version + '-x86_64'
    app = (packages / (base + '.AppImage')).resolve(strict=True)
    provenance_path = packages / (base + '.provenance.json')
    before = file_record(app)
    extracted.mkdir()  # The AppImage never extracts over previous output.
    subprocess.run([str(app), '--appimage-extract'], cwd=extracted, check=True,
                   stdout=subprocess.DEVNULL)
    require(file_record(app) == before, 'AppImage changed during extraction')
    tree = extracted / 'squashfs-root'
    require((tree / 'AppRun').is_file() and (tree / 'usr').is_dir(), 'final AppImage/AppRun payload missing')
    ties = payload_ties(tree / 'usr', policy.load(provenance_path))
    # Cover every dynamic ELF, including additions outside usr made by packaging.
    closure = policy.payload_closure(root, tree)
    return dict(schemaVersion=1, appImage=before, provenanceSHA256=policy.sha(provenance_path),
                selectedPayloadSHA256=ties, closure=closure,
                scope='extracted final AppImage including AppRun; never dist/stage')


def source_metadata(archive, expected):
    actual = {}
    with tarfile.open(archive, 'r|gz') as source:
        for member in source:
            parts = Path(member.name).parts
            relative = '/'.join(parts[1:])
            if relative in expected:
                require(relative not in actual and member.isfile(), 'duplicate/nonfile source metadata')
                digest = hashlib.sha256()
                with source.extractfile(member) as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(block)
                actual[relative] = digest.hexdigest()
    require(actual == expected, 'source metadata differs from final review inputs')


def verify_sources(root, archive, commit, lock_sha, metadata):
    spec = importlib.util.spec_from_file_location('csd_sources', root / 'scripts/verify-csd-sources.py')
    sources = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sources)
    result = sources.verify_bundle(archive, commit, lock_sha)
    source_metadata(archive, metadata)
    return result


def inventory(root, directory, version, with_receipt=False):
    package_names = names(version)
    source_name = 'PerformanceDashboard-' + version + '-sources.tar.gz'
    expected = package_names | EVIDENCE | {source_name}
    exact_files(directory, expected | ({RECEIPT} if with_receipt else set()))
    commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    require(re.fullmatch('[0-9a-f]{40}', commit), 'exact application commit missing')
    dirty = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True)
    require(not dirty.strip(), 'application sources dirty')
    config, lock_path, _ = policy.settings(root)
    container = policy.load(directory / 'container-inputs.json')
    cache = policy.load(directory / 'pd-csd-cache-receipt.json')
    theme = policy.load(directory / 'theme-receipt.json')
    backend = policy.load(directory / 'backend-closure.json')
    closure = policy.load(directory / 'payload-closure.json')
    base = 'PerformanceDashboard-' + version + '-x86_64'
    prov = policy.load(directory / (base + '.provenance.json'))
    app = directory / (base + '.AppImage')
    require(prov['kind'] == 'performance-dashboard-custom-csd-review-provenance'
            and prov['version'] == version and prov['commit'] == commit and prov['sourceDirty'] is False,
            'final provenance version/commit/clean-source mismatch')
    lock_sha = policy.sha(lock_path)
    require(prov['inputs']['customToolchain']['lockSHA256'] == lock_sha == cache['lockSHA256'], 'final lock mismatch')
    require(prov['inputs']['customToolchain']['sdkProvenanceSHA256'] == cache['sdkProvenanceSHA256'], 'final SDK provenance mismatch')
    require(prov['inputs']['adwaita']['buildReceipt'] == theme, 'final theme receipt mismatch')
    require(cache['cacheKey'] == policy.cache_key(root, container)
            and cache['buildContainerInputs'] == container, 'final container/cache binding mismatch')
    require(backend['unexpected'] == [] and backend['backendBuildLogSHA256'] == cache['backendBuildLogSHA256'], 'final backend gate mismatch')
    require(closure['appImage'] == file_record(app)
            and closure['provenanceSHA256'] == policy.sha(directory / (base + '.provenance.json')),
            'final extraction AppImage/provenance binding mismatch')
    require(closure['closure']['elfCount'] > 0
            and closure['selectedPayloadSHA256'] == {name: item['sha256'] for name, item in provenance_ties(prov).items()},
            'final extraction closure/provenance inventory mismatch')
    feed = policy.load(directory / (base + '.update-feed.json'))
    require(feed['package']['version'] == version and len(feed['releases']) == 1
            and feed['releases'][0]['version'] == version, 'review feed version inventory mismatch')
    assets = feed['releases'][0]['assets']
    require(len(assets) == 1 and assets[0]['name'] == app.name, 'review feed asset inventory mismatch')
    for entry, file in [(assets[0], app), (assets[0]['zsync'], directory / (base + '.AppImage.zsync'))]:
        require(entry['name'] == file.name and entry['sha256'] == policy.sha(file)
                and entry['sizeBytes'] == file.stat().st_size, 'review feed bytes mismatch')
    require(not any(assets[0].get(key) for key in ('edSignature', 'versionSignature')), 'review asset unexpectedly signed')
    metadata = policy.load(directory / (base + '.metadata.json'))
    require(metadata['package']['version'] == version, 'packager metadata version mismatch')
    for field, file in [('appImage', app), ('zsync', directory / (base + '.AppImage.zsync')),
                        ('updateFeed', directory / (base + '.update-feed.json'))]:
        record = metadata['artifacts'][field]
        require(Path(record['path']).name == file.name and record['sha256'] == policy.sha(file)
                and record['sizeBytes'] == file.stat().st_size, 'packager metadata bytes mismatch')
    source_result = verify_sources(root, directory / source_name, commit, lock_sha, {
        'metadata/' + name: policy.sha(directory / name) for name in
        ('container-inputs.json', 'theme-receipt.json', 'pd-csd-cache-receipt.json')
    } | {'metadata/gnustep-toolchain-provenance.json': cache['sdkProvenanceSHA256'],
         'metadata/pd-csd-build-sources.json': cache['buildSourcesSHA256']})
    require(source_result == policy.load(directory / 'sources-verification.json'), 'source read-back receipt mismatch')
    return dict(schemaVersion=1, kind='unsigned-csd-producer-aggregate', version=version, applicationCommit=commit,
                toolchainLockSHA256=lock_sha,
                reviewInputsSHA256=policy.sha(root / config['reviewInputs']),
                builderCommit=container['builderCommit'], reviewImageID=container['reviewImageID'],
                cacheIdentity=container['cacheIdentity'], themeReceiptSHA256=policy.sha(directory / 'theme-receipt.json'),
                files={name: file_record(directory / name) for name in sorted(expected)},
                scope='exact unsigned review inventory; runtime/visual qualification separate')


def verify_receipt(root, directory, version):
    result = inventory(root, directory, version, True)
    require((directory / RECEIPT).read_text() == canonical(result), 'canonical aggregate read-back mismatch')
    return policy.sha(directory / RECEIPT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'extract', 'assemble', 'verify'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--version', required=True)
    for option in ('packages', 'directory', 'extracted', 'output'):
        parser.add_argument('--' + option, type=Path)
    args = parser.parse_args()
    try:
        spec = importlib.util.spec_from_file_location('custom_mode', args.root / '.github/scripts/release-selection.py')
        selection = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(selection)
        selection.custom_version(args.root / 'packaging/package.manifest.json', args.root / 'packaging/linux/release-production.json',
                                 os.environ.get('CSD_MODE', 'review'), args.version)
        if args.command == 'prepare':
            prepare(args.packages, args.directory, args.version)
        elif args.command == 'extract':
            result = extract(args.root, args.packages, args.version, args.extracted)
            with args.output.open('x') as dest:
                dest.write(canonical(result))
        elif args.command == 'assemble':
            result = inventory(args.root, args.directory, args.version)
            with (args.directory / RECEIPT).open('x') as dest:
                dest.write(canonical(result))
        else:
            print(verify_receipt(args.root, args.directory, args.version) + '  ' + RECEIPT)
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, EOFError, subprocess.SubprocessError) as error:
        parser.exit(1, 'CSD final review refused: ' + str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
