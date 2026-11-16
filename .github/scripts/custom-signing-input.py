#!/usr/bin/env python3
"""Read-only producer/environment gate and digest-checked artifact extraction."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import zipfile

REPOSITORY = 'danjboyd/gnustep-performance-dashboard'


def require(value, message):
    if not value:
        raise ValueError(message)


def validate(run, artifacts, environment, commit, run_id, environment_name):
    require(re.fullmatch('[0-9a-f]{40}', commit) and re.fullmatch('[1-9][0-9]*', run_id), 'exact commit/run ID required')
    require(re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', environment_name), 'invalid protected environment name')
    require(run.get('id') == int(run_id) and run.get('head_sha') == commit
            and run.get('status') == 'completed' and run.get('conclusion') == 'success', 'producer run is not exact-head successful')
    require(run.get('head_repository', {}).get('full_name') == REPOSITORY
            and run.get('repository', {}).get('full_name') == REPOSITORY, 'foreign producer repository')
    require(run.get('path') in ('.github/workflows/release.yml', '.github/workflows/csd-review.yml')
            and run.get('event') in ('push', 'workflow_dispatch'), 'not an approved custom producer workflow/event')
    require(artifacts.get('total_count') == len(artifacts.get('artifacts', [])), 'complete artifact metadata page required')
    candidates = [a for a in artifacts.get('artifacts', []) if a.get('name') == 'custom-csd-unsigned-production']
    require(len(candidates) == 1 and not candidates[0].get('expired'), 'one unexpired production artifact required')
    artifact = candidates[0]
    require(isinstance(artifact.get('id'), int) and artifact['id'] > 0, 'artifact ID missing')
    digest = artifact.get('digest', '')
    require(isinstance(digest, str) and re.fullmatch('sha256:[0-9a-f]{64}', digest), 'artifact API SHA256 digest required')
    require(environment.get('name') == environment_name
            and any(rule.get('type') == 'required_reviewers' and rule.get('reviewers')
                    for rule in environment.get('protection_rules', [])), 'existing reviewer-protected environment required')
    return dict(commit=commit, producerRunID=run_id, artifactID=str(artifact['id']),
                artifactSHA256=digest.split(':')[1], environment=environment_name)


def unpack(archive, digest, output):
    require(not output.exists(), 'artifact output already exists')
    hasher = hashlib.sha256()
    with archive.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(block)
    require(hasher.hexdigest() == digest, 'downloaded artifact digest mismatch')
    with zipfile.ZipFile(archive) as source:
        files = source.infolist()
        names = [entry.filename for entry in files]
        require(len(names) == len(set(names)), 'duplicate artifact members')
        require(sum(entry.file_size for entry in files) <= 4 * 1024**3, 'artifact exceeds extraction bound')
        for entry in files:
            path = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            require(len(path.parts) == 1 and path.name not in ('', '.', '..') and not path.is_absolute()
                    and entry.filename == path.name and not entry.is_dir() and '\\' not in entry.filename
                    and (stat.S_IFMT(mode) in (0, stat.S_IFREG)), 'nonflat/link/unsafe artifact member')
        output.mkdir(parents=True)
        for entry in files:
            with source.open(entry) as src, (output / entry.filename).open('xb') as dst:
                shutil.copyfileobj(src, dst)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    gate = commands.add_parser('validate')
    for key in ('run', 'artifacts', 'environment-json', 'request-output'):
        gate.add_argument('--' + key, type=Path, required=True)
    for key in ('commit', 'run-id', 'environment'):
        gate.add_argument('--' + key, required=True)
    extract = commands.add_parser('unpack')
    extract.add_argument('--archive', type=Path, required=True)
    extract.add_argument('--request', type=Path, required=True)
    extract.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'validate':
            result = validate(json.loads(args.run.read_text()), json.loads(args.artifacts.read_text()),
                              json.loads(args.environment_json.read_text()), args.commit, args.run_id, args.environment)
            with args.request_output.open('x') as out:
                json.dump(result, out, sort_keys=True)
                out.write('\n')
            for key in ('artifactID', 'artifactSHA256', 'environment'):
                print(key + '=' + result[key])
        else:
            unpack(args.archive, json.loads(args.request.read_text())['artifactSHA256'], args.output)
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, 'Custom signing input refused: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
