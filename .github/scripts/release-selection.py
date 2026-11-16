#!/usr/bin/env python3
"""Select an unsigned release producer from committed inputs, never a secret."""
import argparse
import json
from pathlib import Path
import re


def select(manifest, production, ref, override=''):
    config = json.loads(Path(production).read_text())
    if config.get('schemaVersion') != 1 or config.get('linuxProducer') not in ('managed', 'custom-csd'):
        raise ValueError('Explicit managed/custom-csd release producer required')
    base = json.loads(Path(manifest).read_text())['package']['version']
    version = ref[len('refs/tags/v'):] if ref.startswith('refs/tags/v') else override or base
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version) or version.split('-', 1)[0] != base:
        raise ValueError('Release version must match package.version')
    return {'version': version, 'producer': config['linuxProducer']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', default='packaging/package.manifest.json')
    parser.add_argument('--production', default='packaging/linux/release-production.json')
    parser.add_argument('--ref', required=True)
    parser.add_argument('--version', default='')
    args = parser.parse_args()
    try:
        result = select(args.manifest, args.production, args.ref, args.version)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\n')
    for name, value in result.items():
        print(name + '=' + value)


if __name__ == '__main__':
    main()
