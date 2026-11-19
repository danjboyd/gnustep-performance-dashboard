#!/usr/bin/env python3
"""CI identity/cache/receipt policy; importable for offline static tests."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

NAMES = ['libobjc2', 'libdispatch', 'tools-make', 'libs-base', 'libs-corebase', 'libs-gui', 'libs-back']


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def settings(root):
    config = load(root / 'packaging/linux/csd-ci-inputs.json')
    lock_path = root / config['lock']
    lock = load(lock_path)
    require(lock['install_domain'] == 'LOCAL', 'LOCAL custom SDK required')
    require([c['name'] for c in lock['components']] == NAMES, 'wrong component inventory/order')
    for component in lock['components']:
        for patch in component.get('patches', []):
            file = (lock_path.parent / patch['path']).resolve(strict=True)
            require(file.is_relative_to(lock_path.parent.resolve()), 'patch escapes lock directory')
            require(sha(file) == patch['sha256'], 'patch digest mismatch')
    if 'reviewInputs' in config:
        manifest_path = root / config['reviewInputs']
        manifest = load(manifest_path)
        require(sha(lock_path) == manifest['toolchainLock']['sha256'], 'combined review lock mismatch')
        for patch in manifest['applicationPatches']:
            require(sha(root / patch['path']) == patch['sha256'], 'application patch mismatch')
            applied = patch['appliedSource']
            require(sha(root / applied['path']) == applied['sha256'], 'application source mismatch')
        require(config['fallbackSource'] == load(root / 'packaging/linux/robin-map-source.json'), 'fallback pin drift')
    return config, lock_path, lock


def cache_key(root, state):
    config, lock_path, _ = settings(root)
    require(state['builderCommit'] == config['builder']['revision'], 'wrong builder identity')
    require(re.fullmatch('[0-9a-f]{64}', state['cacheIdentity']) is not None, 'missing container fingerprint')
    return 'pd-csd-sdk-v1-linux-amd64-' + sha(lock_path) + '-' + config['builder']['revision'] + '-' + sha(root / 'packaging/linux/csd-ci-inputs.json') + '-' + state['cacheIdentity'] + '-' + (sha(root / config['reviewInputs']) if 'reviewInputs' in config else 'fixture')


def builder_identity(root, builder):
    config, _, _ = settings(root)
    head = subprocess.check_output(['git', '-C', str(builder), 'rev-parse', 'HEAD'], text=True).strip()
    require(head == config['builder']['revision'], 'wrong builder checkout')
    dirty = subprocess.check_output(['git', '-C', str(builder), 'status', '--porcelain', '--untracked-files=no'], text=True)
    require(not dirty.strip(), 'builder tracked sources changed')
    for relative, digest in load(root / 'docs/v017-builder-source-digests.json')['fileSHA256'].items():
        require(sha(builder / relative) == digest, 'inspected builder file changed: ' + relative)
    return dict(builderCommit=head, sourceClean=True)


def fingerprint(root, builder, inventory, base_digest, image_id, uid, gid):
    config, _, _ = settings(root)
    expected = load(root / 'docs/v017-builder-source-digests.json')
    for relative, digest in expected['fileSHA256'].items():
        require(sha(builder / relative) == digest, 'inspected builder file changed: ' + relative)
    require('@sha256:' in base_digest, 'resolved base image digest required')
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', image_id), 'resolved review image ID required')
    packages = inventory.read_text().splitlines()
    require(packages and all('\t' in line for line in packages), 'resolved package inventory required')
    identity = dict(baseImageDigest=base_digest, packageInventorySHA256=sha(inventory),
                    builderDockerfileSHA256=sha(builder / 'toolchains/linux-amd64-clang/Dockerfile'),
                    reviewDockerfileSHA256=sha(root / '.github/containers/csd-review.Dockerfile'),
                    target='linux-amd64-clang', uid=uid, gid=gid, reviewImageID=image_id)
    return dict(schemaVersion=1, builderCommit=config['builder']['revision'],
                cacheIdentity=hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest(),
                identity=identity, reviewImageID=image_id, distributionPackages=packages,
                qualification='inventory-attested; not bit-reproducible')


def record_build_sources(root, prefix):
    config, _, _ = settings(root)
    fallback = config['fallbackSource']
    tree = prefix.parent / '.sdk-build/sources/libobjc2/build/_deps/robinmap-src'
    require((tree / '.git').exists(), 'unrecorded robin-map provider; expected verified FetchContent checkout')
    resolved = subprocess.check_output(['git', '-C', str(tree), 'rev-parse', 'HEAD'], text=True).strip()
    remote = subprocess.check_output(['git', '-C', str(tree), 'remote', 'get-url', 'origin'], text=True).strip()
    normalize = lambda value: value.rstrip('/').removesuffix('.git')
    require(resolved == fallback['revision'] and normalize(remote) == normalize(fallback['url']), 'fallback source identity changed')
    dirty = subprocess.check_output(['git', '-C', str(tree), 'status', '--porcelain', '--untracked-files=no'], text=True)
    require(not dirty.strip(), 'fallback source modified')
    return dict(schemaVersion=1, provider='CMake FetchContent', gitSources=[dict(fallback, resolvedCommit=resolved)])


def validate_sdk(root, prefix, state, receipt_required=True):
    config, lock_path, lock = settings(root)
    prefix = prefix.resolve(strict=True)
    provenance = load(prefix / 'gnustep-toolchain-provenance.json')
    require(provenance.get('schema_version') == 1 and provenance.get('kind') == 'custom-gnustep-toolchain-provenance', 'wrong SDK provenance format')
    require(provenance.get('official') is False and provenance.get('install_domain') == 'LOCAL', 'not custom LOCAL SDK')
    require(provenance.get('prefix') == str(prefix), 'cached SDK prefix moved; refuse absolute-path rewriting')
    require(provenance.get('lock', {}).get('sha256') == sha(lock_path), 'SDK lock mismatch')
    actual = provenance.get('components', [])
    require(len(actual) == len(lock['components']), 'SDK component count mismatch')
    for source, built in zip(lock['components'], actual):
        require(built.get('name') == source['name'] and built.get('url') == source['url']
                and built.get('revision') == source['revision'] and built.get('resolved_commit') == source['revision']
                and built.get('configure_args', []) == source.get('configure_args', [])
                and built.get('applied_patches', []) == source.get('patches', []), 'SDK source/patch mismatch')
    require((prefix / 'System/Library/Makefiles/GNUstep.sh').is_file(), 'SDK activation missing')
    files = provenance.get('elf_files', {})
    require(bool(files), 'SDK has no ELF inventory')
    for relative, record in files.items():
        file = (prefix / relative).resolve(strict=True)
        require(file.is_relative_to(prefix), 'SDK inventory path escapes prefix')
        require(sha(file) == record['sha256'], 'SDK payload hash mismatch: ' + relative)
    if 'reviewInputs' in config:
        require(re.search(r'^#define HAVE_XFIXES 1$', (prefix / 'pd-backend-config.h').read_text(), re.M), 'built backend lacks HAVE_XFIXES')
    build_sources = load(prefix / 'pd-csd-build-sources.json')
    require(build_sources.get('gitSources') == [dict(config['fallbackSource'], resolvedCommit=config['fallbackSource']['revision'])], 'fallback source receipt mismatch')
    symlinks = {}
    actual_elf = set()
    for file in prefix.rglob('*'):
        if file.is_symlink():
            target = file.resolve(strict=True)
            require('.so' not in file.name or target.is_relative_to(prefix), 'SDK library symlink escapes prefix')
            symlinks[str(file.relative_to(prefix))] = str(file.readlink())
        elif file.is_file():
            with file.open('rb') as stream:
                if stream.read(4) == b'\x7fELF':
                    actual_elf.add(str(file.relative_to(prefix)))
    require(actual_elf == set(files), 'SDK ELF inventory incomplete/unexplained')
    for relative, record in files.items():
        if record.get('build_id'):
            notes = subprocess.check_output(['readelf', '-n', str(prefix / relative)], text=True)
            match = re.search(r'Build ID:\s*([0-9a-fA-F]+)', notes)
            require(match and match.group(1).lower() == record['build_id'].lower(), 'SDK build ID mismatch')
    receipt = dict(schemaVersion=1, symlinks=symlinks, cacheKey=cache_key(root, state), lockSHA256=sha(lock_path),
                   sdkProvenanceSHA256=sha(prefix / 'gnustep-toolchain-provenance.json'),
                   backendBuildLogSHA256=sha(prefix / 'pd-backend-build.log'),
                   backendConfigSHA256=sha(prefix / 'pd-backend-config.h') if 'reviewInputs' in config else None,
                   buildSourcesSHA256=sha(prefix / 'pd-csd-build-sources.json'), buildContainerInputs=state)
    if receipt_required:
        saved = load(prefix / 'pd-csd-cache-receipt.json')
        for field in ('cacheKey', 'lockSHA256', 'sdkProvenanceSHA256', 'backendBuildLogSHA256', 'buildSourcesSHA256', 'symlinks', 'backendConfigSHA256'):
            require(saved.get(field) == receipt[field], 'cache receipt identity mismatch')
        require(saved['buildContainerInputs']['cacheIdentity'] == state['cacheIdentity'], 'cache container inventory changed')
    return receipt


def theme_receipt(root, prefix, theme, log):
    _, lock_path, _ = settings(root)
    revision = load(root / 'packaging/release-inputs.json')['adwaita']['revision']
    head = subprocess.check_output(['git', '-C', str(theme), 'rev-parse', 'HEAD'], text=True).strip()
    require(head == revision, 'theme source revision mismatch')
    dirty = subprocess.check_output(['git', '-C', str(theme), 'status', '--porcelain', '--untracked-files=no'], text=True)
    require(not dirty.strip(), 'theme tracked sources changed')
    require(log.is_file() and log.stat().st_size > 0, 'successful theme build log required')
    return dict(schemaVersion=1, themeSourceRevision=revision, themeBinarySHA256=sha(theme / 'Adwaita.theme/Adwaita'),
                toolchainLockSHA256=sha(lock_path), toolchainProvenanceSHA256=sha(prefix / 'gnustep-toolchain-provenance.json'),
                buildLogSHA256=sha(log), buildJobs=2, sourceClean=True)


def check_closure(root, backend, build_log):
    require(build_log.is_file() and build_log.stat().st_size > 0, 'backend compile/link log missing')
    output = subprocess.check_output(['readelf', '-d', str(backend)], text=True)
    needed = sorted(re.findall(r'\(NEEDED\).*?\[([^]]+)\]', output))
    config, _, _ = settings(root)
    baseline = load(root / config['backendNeededPolicy'])
    require(needed == sorted(baseline['expectedNeeded']), 'unexpected backend DT_NEEDED or missing required entry')
    text = build_log.read_text()
    require(any('clang' in line and ' -shared ' in line and 'gnustep-back' in line
                for line in text.splitlines()), 'executed verbose backend linker command missing')
    return dict(backendSHA256=sha(backend), actualNeeded=needed, unexpected=[],
                backendBuildLogSHA256=sha(build_log), policy='exact retained plus XFixes; verbose linker evidence')


def payload_closure(root, prefix):
    # Resolve every final extracted ELF in the same image, enforcing host exclusions.
    import importlib.util
    spec = importlib.util.spec_from_file_location('stage_runtime', root / 'scripts/stage-linux-runtime.py')
    stage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stage)
    records = []
    library_root = prefix / 'usr/runtime/lib' if (prefix / 'usr/runtime/lib').is_dir() else prefix / 'runtime/lib'
    for file in prefix.rglob('*'):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        dynamic = subprocess.check_output(['readelf', '-d', str(file)], text=True)
        if '(NEEDED)' not in dynamic:
            continue
        import os
        result = subprocess.run(['ldd', str(file)], text=True, capture_output=True,
            env=dict(os.environ, LD_LIBRARY_PATH=str(library_root.resolve())))
        require(result.returncode == 0 and 'not found' not in result.stdout, 'unresolved staged ELF dependency')
        for name, resolved in re.findall(r'^\s*(\S+) => (\S+)', result.stdout, re.M):
            if resolved.startswith('/') and not Path(resolved).resolve().is_relative_to(prefix.resolve()):
                require(stage.HOST_LIBRARIES.fullmatch(name), 'unreviewed host dependency: ' + name)
        records.append(dict(path=str(file.relative_to(prefix)), resolution=result.stdout))
    require(records, 'no dynamic staged ELF closure')
    return dict(elfCount=len(records), records=records, policy='no missing or unreviewed host dependencies')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['fingerprint', 'cache-key', 'sdk-verify', 'theme-receipt', 'closure', 'build-sources', 'payload-closure', 'builder-check'])
    parser.add_argument('--root', type=Path, required=True)
    for name in ('builder', 'inventory', 'state', 'prefix', 'theme', 'log', 'backend', 'output'):
        parser.add_argument('--' + name, type=Path)
    for name in ('base-digest', 'image-id', 'uid', 'gid'):
        parser.add_argument('--' + name)
    parser.add_argument('--write-receipt', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'builder-check':
            result = builder_identity(args.root, args.builder)
        elif args.command == 'fingerprint':
            result = fingerprint(args.root, args.builder, args.inventory, args.base_digest, args.image_id, args.uid, args.gid)
        elif args.command == 'cache-key':
            print(cache_key(args.root, load(args.state)))
            return 0
        elif args.command == 'sdk-verify':
            result = validate_sdk(args.root, args.prefix, load(args.state), not args.write_receipt)
            if args.write_receipt:
                (args.prefix / 'pd-csd-cache-receipt.json').write_text(json.dumps(result, indent=2) + '\n')
        elif args.command == 'build-sources':
            result = record_build_sources(args.root, args.prefix)
        elif args.command == 'theme-receipt':
            result = theme_receipt(args.root, args.prefix, args.theme, args.log)
        elif args.command == 'payload-closure':
            result = payload_closure(args.root, args.prefix)
        else:
            result = check_closure(args.root, args.backend, args.log)
        if args.output:
            args.output.write_text(json.dumps(result, indent=2) + '\n')
        else:
            print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        parser.exit(1, 'CSD CI identity check failed: ' + str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
