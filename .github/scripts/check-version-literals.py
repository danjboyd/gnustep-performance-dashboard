#!/usr/bin/env python3
"""Fail CI on frozen release versions in executable scripts/workflows."""
import argparse
import json
from pathlib import Path
import re

# Also catch the unprefixed asset spelling that escaped an earlier tag edit.
PATTERN = re.compile(r'v0\.1\.[0-9]+|v0[0-9]{2,}|PerformanceDashboard-0\.1\.[0-9]+')


def check(root):
    root = Path(root)
    entries = json.loads((root / 'docs/ci-version-literals.allowlist.json').read_text())
    counts = [0] * len(entries)
    for entry in entries:
        if not entry['literal'].startswith('docs/') or not entry['reason'].strip():
            raise ValueError('Only explicit documented baseline references may be allowlisted')
    failures = []
    for directory in ('.github/scripts', '.github/workflows'):
        for path in sorted((root / directory).rglob('*')):
            if not path.is_file() or '__pycache__' in path.parts:
                continue
            relative = path.relative_to(root).as_posix()
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for hit in PATTERN.finditer(line):
                    allowed = False
                    for i, entry in enumerate(entries):
                        if relative == entry['file']:
                            for occurrence in re.finditer(re.escape(entry['literal']), line):
                                if occurrence.start() <= hit.start() and hit.end() <= occurrence.end():
                                    counts[i] += 1
                                    allowed = True
                    if not allowed:
                        failures.append(f'{relative}:{number}: {line.strip()}')
    for entry, count in zip(entries, counts):
        if count != entry['count']:
            failures.append('Stale documentation allowlist entry: ' + entry['literal'])
    if failures:
        raise ValueError('\n'.join(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        check(args.root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\n')
    print('PASS no hardcoded release versions in scripts/workflows')


if __name__ == '__main__':
    main()
