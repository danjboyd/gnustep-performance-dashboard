#!/usr/bin/env python3
"""Collect/check corresponding sources for the unsigned custom CSD artifact.

The collector runs only in a disposable Debian builder, after real staging.
Offline tests use synthetic source trees and archives, without network/builds.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('csd_ci_state', ROOT / '.github/scripts/csd-review-state.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def codeload(source):
    match = re.fullmatch(r'https://github.com/([^/]+/[^/]+?)(?:\.git)?/?', source['url'])
    policy.require(match is not None, 'source URL must name the reviewed public GitHub repository')
    policy.require(re.fullmatch('[0-9a-f]{40}', source['revision']) is not None, 'full source commit required')
    return 'https://codeload.github.com/' + match.group(1) + '/tar.gz/' + source['revision']


def git_sources(root, lock, build_sources):
    config, _, _ = policy.settings(root)
    inputs = policy.load(root / 'packaging/release-inputs.json')
    fallback = config['fallbackSource']
    policy.require(build_sources.get('gitSources') == [dict(fallback, resolvedCommit=fallback['revision'])],
                   'actual fallback source receipt does not match the reviewed identity')
    records = [dict(name=c['name'], url=c['url'], revision=c['revision']) for c in lock['components']]
    records += [dict(inputs['gnustep-trellis'], name='gnustep-trellis'), dict(inputs['adwaita'], name='adwaita'), dict(inputs['gnustep-packager'], name='gnustep-packager'),
                dict(config['builder'], name='gnustep-cli-new'), dict(fallback)] + config['auxiliarySources']
    policy.require(len({r['name'] for r in records}) == len(records), 'duplicate source identity')
    for record in records:
        record['archiveURL'] = codeload(record)
        record['archiveFile'] = 'git-sources/' + record['name'] + '-' + record['revision'] + '.tar.gz'
    return records


def member_path(directory, relative):
    value = PurePosixPath(relative)
    policy.require(value.parts and not value.is_absolute() and '..' not in value.parts, 'unsafe manifest path')
    path = directory.joinpath(*value.parts).resolve(strict=True)
    policy.require(path.is_relative_to(directory.resolve()), 'manifest path escapes source tree')
    return path


def write_checksums(directory):
    (directory / 'SHA256SUMS').write_text(''.join(
        policy.sha(p) + '  ' + str(p.relative_to(directory)) + '\n'
        for p in sorted(directory.rglob('*')) if p.is_file() and p.name != 'SHA256SUMS'))


def verify_distribution(directory, manifest):
    binaries = manifest['distributionBinaries']
    listed_packages = {line.split('\t')[1].strip() for line in
                       (directory / 'metadata/host-libraries.txt').read_text().splitlines() if '\t' in line}
    policy.require(listed_packages and {item['package'] for item in binaries} == listed_packages, 'distribution binary source inventory differs')
    expected = {(item['name'], item['revision']) for item in manifest['distributionSources']}
    policy.require({(item['source'], item['revision']) for item in binaries} == expected, 'distribution source mapping differs')
    found = set()
    for descriptor in (directory / 'debian').glob('*.dsc'):
        text = descriptor.read_text()
        name = re.search(r'^Source: (\S+)', text, re.M)
        revision = re.search(r'^Version: (\S+)', text, re.M)
        policy.require(name is not None and revision is not None, 'Debian source descriptor identity missing')
        fields = re.search(r'^Checksums-Sha256:\n((?: [^\n]*\n)+)', text, re.M)
        policy.require(fields is not None, 'Debian source SHA inventory missing')
        for line in fields.group(1).splitlines():
            digest, size, filename = line.split()
            file = member_path(directory, 'debian/' + filename)
            policy.require(file.stat().st_size == int(size) and policy.sha(file) == digest, 'Debian corresponding source differs/missing')
        found.add((name.group(1), revision.group(1)))
    policy.require(found == expected, 'matching Debian source descriptor missing')


def verify_tree(directory, commit, expected_lock_sha):
    manifest = policy.load(directory / 'sources.json')
    policy.require(manifest['applicationCommit'] == commit, 'application source commit mismatch')
    lock_path = member_path(directory, manifest['lockFile'])
    policy.require(policy.sha(lock_path) == expected_lock_sha == manifest['customToolchainLockSHA256'], 'source lock digest mismatch')
    lock = policy.load(lock_path)
    listed = manifest['gitSources']
    by_name = {entry['name']: entry for entry in listed}
    policy.require(len(by_name) == len(listed), 'duplicate Git source records')
    expected = {c['name']: (c['url'], c['revision']) for c in lock['components']}
    for field in ('trellisSource', 'themeSource', 'builderSource', 'packagerSource', 'fallbackSource'):
        value = manifest[field]
        expected[value['name']] = (value['url'], value['revision'])
    for name, (url, revision) in expected.items():
        entry = by_name.get(name)
        policy.require(entry is not None and entry['url'] == url and entry['revision'] == revision,
                       'missing/wrong corresponding source: ' + name)
    policy.require(by_name[manifest['fallbackSource']['name']]['archiveSHA256'] == manifest['fallbackSource']['archiveSHA256'], 'fallback archive pin mismatch')
    for entry in listed:
        policy.require(entry['archiveURL'] == codeload(entry), 'public archive URL differs from exact source')
        path = member_path(directory, entry['archiveFile'])
        policy.require(policy.sha(path) == entry['archiveSHA256'], 'Git source archive digest mismatch')
        with tarfile.open(path, 'r|gz') as source:
            policy.require(any(member.isfile() for member in source), 'empty Git source archive')
    objc = by_name['libobjc2']
    evidence = manifest['fallbackSource']['upstreamBuildDescription']
    policy.require(evidence['libobjc2Revision'] == objc['revision'], 'fallback build-description revision differs')
    with tarfile.open(member_path(directory, objc['archiveFile'])) as source:
        cmake = next((m for m in source if len(PurePosixPath(m.name).parts) == 2
                      and m.name.endswith('/CMakeLists.txt') and m.isfile()), None)
        policy.require(cmake is not None, 'fallback CMake evidence missing')
        policy.require(hashlib.sha256(source.extractfile(cmake).read()).hexdigest() == evidence['sha256'],
                       'fallback CMake evidence changed')
    expected_patches = [(c['name'], p['path'], p['sha256']) for c in lock['components'] for p in c.get('patches', [])]
    actual_patches = [(p['component'], p['lockPath'], p['sha256']) for p in manifest['patches']]
    policy.require(expected_patches == actual_patches, 'source patch inventory/order mismatch')
    for patch in manifest['patches']:
        policy.require(policy.sha(member_path(directory, patch['file'])) == patch['sha256'], 'corresponding patch bytes differ')
    index_path = member_path(directory, manifest['publicBackportIndex']['file'])
    policy.require(policy.sha(index_path) == manifest['publicBackportIndex']['sha256'], 'public backport index digest mismatch')
    for item in policy.load(index_path)['patches']:
        policy.require(item['originalPatchURL'].startswith('https://github.com/'), 'original public patch URL missing')
    sdk_path = directory / 'metadata/gnustep-toolchain-provenance.json'
    sdk = policy.load(sdk_path)
    policy.require(sdk.get('official') is False and sdk.get('lock', {}).get('sha256') == expected_lock_sha, 'SDK provenance lock differs')
    policy.require(len(sdk['components']) == len(lock['components']), 'source SDK component inventory differs')
    for source, built in zip(lock['components'], sdk['components']):
        policy.require(built['name'] == source['name'] and built['url'] == source['url']
                       and built['resolved_commit'] == source['revision']
                       and built['applied_patches'] == source.get('patches', []), 'source SDK identity differs')
    receipt = policy.load(directory / 'metadata/theme-receipt.json')
    policy.require(receipt['themeSourceRevision'] == manifest['themeSource']['revision']
                   and receipt['toolchainLockSHA256'] == expected_lock_sha
                   and receipt['toolchainProvenanceSHA256'] == policy.sha(sdk_path), 'theme source receipt differs')
    build_sources = policy.load(directory / 'metadata/pd-csd-build-sources.json')
    fallback = manifest['fallbackSource']
    policy.require(build_sources['gitSources'] == [dict(fallback, resolvedCommit=fallback['revision'])], 'actual fallback source differs')
    container = policy.load(directory / 'metadata/container-inputs.json')
    policy.require(container['builderCommit'] == manifest['builderSource']['revision'], 'builder source differs')
    cache = policy.load(directory / 'metadata/pd-csd-cache-receipt.json')
    policy.require(cache['sdkProvenanceSHA256'] == policy.sha(sdk_path)
                   and cache['buildSourcesSHA256'] == policy.sha(directory / 'metadata/pd-csd-build-sources.json'), 'SDK source-cache receipt differs')
    with tarfile.open(directory / 'PerformanceDashboard.tar') as app:
        policy.require(app.pax_headers.get('comment') == commit, 'application archive commit mismatch')
        release_inputs = json.load(app.extractfile('PerformanceDashboard/packaging/release-inputs.json'))
        config = json.load(app.extractfile('PerformanceDashboard/packaging/linux/csd-ci-inputs.json'))
        for key, name in [('gnustep-trellis', 'trellisSource'), ('adwaita', 'themeSource'), ('gnustep-packager', 'packagerSource')]:
            policy.require(all(manifest[name][field] == release_inputs[key][field] for field in ('url', 'revision')), 'application source pin differs')
        policy.require(all(manifest['builderSource'][field] == config['builder'][field] for field in ('url', 'revision')), 'application builder pin differs')
        policy.require(manifest['fallbackSource'] == config['fallbackSource'], 'application fallback pin differs')
        for source in config['auxiliarySources']:
            policy.require(source['name'] in by_name and all(by_name[source['name']][field] == source[field] for field in ('url', 'revision')), 'auxiliary source missing/different')
        policy.require(set(by_name) == set(expected) | {s['name'] for s in config['auxiliarySources']}, 'unexplained Git source inventory')
        review = json.load(app.extractfile('PerformanceDashboard/' + config['reviewInputs']))
        policy.require(review['toolchainLock']['sha256'] == expected_lock_sha, 'application review lock differs')
        policy.require(review['sdkPatchOrder'] == [dict(component=c['name'], **p) for c in lock['components'] for p in c.get('patches', [])], 'application review SDK order differs')
        for patch in review['applicationPatches']:
            raw = app.extractfile('PerformanceDashboard/' + patch['path']).read()
            policy.require(hashlib.sha256(raw).hexdigest() == patch['sha256'], 'application patch missing/different')
            applied = patch['appliedSource']
            raw = app.extractfile('PerformanceDashboard/' + applied['path']).read()
            policy.require(hashlib.sha256(raw).hexdigest() == applied['sha256'], 'applied application source differs')
        public_index = app.extractfile('PerformanceDashboard/packaging/linux/csd-v7/backports.json').read()
        policy.require(hashlib.sha256(public_index).hexdigest() == manifest['publicBackportIndex']['sha256'], 'application public patch index differs')
        archive_lock = app.extractfile('PerformanceDashboard/' + manifest['applicationLockPath']).read()
        policy.require(hashlib.sha256(archive_lock).hexdigest() == expected_lock_sha, 'application archive lock differs')
        for patch in manifest['patches']:
            raw = app.extractfile('PerformanceDashboard/' + patch['applicationPath']).read()
            policy.require(hashlib.sha256(raw).hexdigest() == patch['sha256'], 'application archive omits/differs patch')
    verify_distribution(directory, manifest)
    sums = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        policy.require(name not in sums, 'duplicate source checksum entry')
        sums[name] = digest
    files = {str(p.relative_to(directory)): p for p in directory.rglob('*') if p.is_file() and p.name != 'SHA256SUMS'}
    policy.require(set(files) == set(sums), 'source checksum inventory incomplete')
    for name, path in files.items():
        policy.require(policy.sha(path) == sums[name], 'source checksum mismatch: ' + name)
    return dict(ok=True, applicationCommit=commit, customToolchainLockSHA256=expected_lock_sha,
                gitSourceCount=len(listed), patchCount=len(manifest['patches']))


def verify_bundle(archive_path, commit, expected_lock_sha):
    # Never extract links/devices or trust archive path names.
    with tempfile.TemporaryDirectory(prefix='pd-source-verify-') as temp:
        target = Path(temp)
        top = None
        with tarfile.open(archive_path, 'r|gz') as archive:
            for member in archive:
                parts = PurePosixPath(member.name).parts
                policy.require(parts and not PurePosixPath(member.name).is_absolute()
                               and '..' not in parts, 'unsafe source bundle path')
                top = top or parts[0]
                policy.require(parts[0] == top, 'source bundle has multiple roots')
                path = target.joinpath(*parts)
                if member.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    policy.require(member.isfile(), 'source bundle contains a link/device')
                    policy.require(not path.exists(), 'duplicate source bundle member')
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, path.open('wb') as dest:
                        shutil.copyfileobj(source, dest)
        policy.require(top is not None, 'empty source bundle')
        return verify_tree(target / top, commit, expected_lock_sha)

