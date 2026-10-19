#!/usr/bin/env python3
"""Map locked Windows binary packages to source packages without executing recipes.

Supply the input-manifest.json and adjacent msys2-sync directory from the
pinned gnustep-cli-new revision. URLs are candidates, not verified downloads.
Use --package repeatedly to limit the result to owners of staged runtime files.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile


def inventory(lock, database_directory, packages=None):
    selected = set(packages or [])
    known = {p['name'] for p in lock['locked_packages']}
    if selected - known:
        raise ValueError(f"Packages absent from toolchain lock: {sorted(selected - known)}")
    databases = {}
    for database in lock['sync_databases']:
        name = database['file']
        if Path(name).name != name:
            raise ValueError('Database filename must be a basename')
        path = database_directory / name
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != database['sha256']:
            raise ValueError(f'Database digest mismatch: {name}')
        if data.startswith(b'\x28\xb5\x2f\xfd'):
            data = subprocess.check_output(['zstd', '-dc', str(path)])
        entries = {}
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive:
                if not member.isfile() or not member.name.endswith('/desc'):
                    continue
                fields = {}
                for block in archive.extractfile(member).read().decode('utf-8').strip().split('\n\n'):
                    lines = block.splitlines()
                    fields[lines[0].strip('%')] = lines[1:]
                key = fields['NAME'][0]
                if key in entries:
                    raise ValueError(f'Duplicate package metadata: {key}')
                entries[key] = fields
        databases[database['repo']] = entries

    sources = {}
    for package in lock['locked_packages']:
        name, repo = package['name'], package['repo']
        if selected and name not in selected:
            continue
        entry = databases[repo].get(name)
        if not entry or entry['VERSION'] != [package['version']] or entry['SHA256SUM'] != [package['sha256']]:
            raise ValueError(f'Binary package differs from snapshot: {name}')
        base, version = entry['BASE'][0], entry['VERSION'][0]
        # Never derive a source package name by stripping architecture prefixes.
        # MSYS2 split packages share the explicit BASE from the pinned database.
        key = (repo, base, version)
        if repo not in ('msys', 'clang64'):
            raise ValueError(f'Unsupported repository: {repo}')
        channel = 'msys' if repo == 'msys' else 'mingw'
        source = sources.setdefault(key, {
            'repository': repo, 'base': base, 'version': version,
            'candidateUrl': f'https://repo.msys2.org/{channel}/sources/{base}-{version}.src.tar.zst',
            'binaryPackages': [], 'licenses': [],
            'verification': 'not downloaded; source completeness not assessed',
        })
        source['binaryPackages'].append(name)
        source['licenses'] = sorted(set(source['licenses'] + entry.get('LICENSE', [])))
    for source in sources.values():
        source['binaryPackages'].sort()
    return {'schemaVersion': 1, 'scope': 'selected packages' if selected else 'entire toolchain',
            'sources': [sources[key] for key in sorted(sources)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-manifest', type=Path, required=True)
    parser.add_argument('--databases', type=Path, required=True)
    parser.add_argument('--package', action='append')
    args = parser.parse_args()
    result = inventory(json.loads(args.input_manifest.read_text()), args.databases, args.package)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
