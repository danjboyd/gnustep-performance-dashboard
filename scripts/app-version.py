#!/usr/bin/env python3
"""Stamp/check app metadata against the effective packager manifest version.

GP_PACKAGE_VERSION is supplied by pinned gnustep-packager to build/stage steps;
plain make falls back to package.version. This never edits tracked source plists.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import tempfile

KEYS = ('CFBundleShortVersionString', 'CFBundleVersion', 'ApplicationRelease', 'FullVersionID')


def effective_version(manifest, environment):
    version = environment.get('GP_PACKAGE_VERSION') or json.loads(Path(manifest).read_text())['package']['version']
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?', version):
        raise ValueError('effective package version is not a supported version string')
    return version


def metadata_path(bundle):
    paths = [Path(bundle) / 'Resources/Info-gnustep.plist', Path(bundle) / 'Contents/Info.plist']
    found = [p for p in paths if p.is_file()]
    if len(found) != 1:
        raise ValueError('exactly one built app Info plist is required')
    return found[0]


def read_versions(path):
    raw = Path(path).read_bytes()
    if raw.lstrip().startswith(b'<?xml') or raw.startswith(b'bplist'):
        data = plistlib.loads(raw)
        return {key: data.get(key) for key in KEYS}
    text = raw.decode('utf-8')
    if not text.lstrip().startswith('{'):
        raise ValueError('unsupported app Info plist format')
    values = {}
    for key in KEYS:
        matches = re.findall(r'^\s*' + key + r'\s*=\s*(?:"([^"\n]*)"|([^;\s]+))\s*;', text, re.M)
        if len(matches) > 1:
            raise ValueError('duplicate app version key: ' + key)
        values[key] = next((a or b for a, b in matches), None)
    return values


def check_bundle(bundle, version):
    values = read_versions(metadata_path(bundle))
    if any(values[key] != version for key in KEYS):
        raise ValueError('app version differs from effective package version ' + version + ': ' + repr(values))
    return values


def stamp_bundle(bundle, version):
    path = metadata_path(bundle)
    raw = path.read_bytes()
    # Parse/check duplicate keys before updating; do not hide malformed input.
    read_versions(path)
    if raw.lstrip().startswith(b'<?xml') or raw.startswith(b'bplist'):
        data = plistlib.loads(raw)
        data.update({key: version for key in KEYS})
        result = plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)
    else:
        text = raw.decode('utf-8')
        for key in KEYS:
            pattern = r'^\s*' + key + r'\s*=\s*(?:"[^"\n]*"|[^;\s]+)\s*;'
            text, count = re.subn(pattern, '\n  ' + key + ' = "' + version + '";', text, flags=re.M)
            if not count:
                at = text.index('{') + 1
                text = text[:at] + '\n  ' + key + ' = "' + version + '";' + text[at:]
        result = text.encode('utf-8')
    mode = stat.S_IMODE(path.stat().st_mode)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.app-version-', delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(result)
            output.flush()
            os.chmod(temporary, mode)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return check_bundle(bundle, version)


def write_product_header(path, version):
    path = Path(path)
    raw = ('/* Generated from the effective package version; not trace format. */\n'
           '#ifndef PD_PRODUCT_VERSION_H\n#define PD_PRODUCT_VERSION_H\n'
           '#define PD_PRODUCT_VERSION ' + json.dumps(version) + '\n#endif\n').encode('ascii')
    if path.is_file() and path.read_bytes() == raw:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.product-version-', delete=False) as output:
        temporary = Path(output.name)
        output.write(raw)
    try:
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['stamp', 'check', 'value'])
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--header', type=Path)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[1] / 'packaging/package.manifest.json')
    parser.add_argument('--version')
    args = parser.parse_args()
    try:
        env = dict(os.environ)
        if args.version is not None:
            env['GP_PACKAGE_VERSION'] = args.version
        version = effective_version(args.manifest, env)
        if args.command == 'value':
            if args.header:
                write_product_header(args.header, version)
            print(version)
            return
        if args.bundle is None:
            parser.error('--bundle is required for stamp/check')
        values = stamp_bundle(args.bundle, version) if args.command == 'stamp' else check_bundle(args.bundle, version)
        print(json.dumps(dict(version=version, bundle=str(args.bundle), values=values), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        parser.exit(1, 'app-version: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
