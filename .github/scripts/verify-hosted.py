#!/usr/bin/env python3
"""Read-only hosted release/feed checks against an explicitly reviewed inventory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


# TODO: Multi-architecture publication needs a combined asset/checksum inventory
# and explicit per-architecture feed endpoints. This verifier currently requires
# exactly seven assets for one architecture and fails closed for a mixed release.
def filenames(version, arch='x86_64'):
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Stable numeric version required')
    require(arch in ('x86_64', 'aarch64'), 'Unsupported Linux architecture')
    stem = f'PerformanceDashboard-{version}'
    feed = stem + f'-{arch}.update-feed.json'
    return {stem + '-sources.tar.gz', stem + f'-{arch}.AppImage',
            stem + f'-{arch}.AppImage.zsync', stem + f'-{arch}.provenance.json',
            feed, 'SHA256SUMS', 'assembly.json'}, feed


def inventory(path, version, arch='x86_64'):
    record = json.loads(Path(path).read_text())
    names, feed = filenames(version, arch)
    require(set(record['files']) == set(record['sizes']) == names,
            'Reviewed inventory must contain exactly the seven version-derived names')
    require(all(re.fullmatch('[0-9a-f]{64}', h) for h in record['files'].values()), 'Invalid reviewed hash')
    require(all(type(n) is int and n > 0 for n in record['sizes'].values()), 'Invalid reviewed size')
    return record, feed


def api(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))


def signature(feed, directory, anchor):
    public = json.loads(Path(anchor).read_text())['publicEDKey']
    # Public anchor only; never inherit private signing credentials.
    env = {'PATH': os.defpath, 'UPDATE_ED_PUBLIC_KEY': public}
    subprocess.run([sys.executable, str(ROOT / 'scripts/sign-update-feed.py'),
                    '--verify', str(feed), str(directory)], env=env, check=True)


def local_assets(directory, record, version, anchor, arch='x86_64'):
    _, feed = filenames(version, arch)
    directory = Path(directory)
    require({p.name for p in directory.iterdir()} == set(record['files']), 'Unexpected/missing downloaded files')
    for name, digest in record['files'].items():
        path = directory / name
        require(path.is_file() and not path.is_symlink(), 'Asset must be a regular file: ' + name)
        require(path.stat().st_size == record['sizes'][name] and sha(path) == digest, 'Asset bytes differ: ' + name)
    sums = (directory / 'SHA256SUMS').read_text().splitlines()
    expected = {name: h for name, h in record['files'].items() if name != 'SHA256SUMS'}
    parsed = {}
    for line in sums:
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        require(match and match[2] not in parsed, 'Malformed or duplicate SHA256SUMS entry')
        parsed[match[2]] = match[1]
    require(parsed == expected, 'SHA256SUMS differs from reviewed inventory')
    contents = json.loads((directory / feed).read_text())
    require(contents['package']['version'] == version and contents['channel'] == 'stable'
            and len(contents['releases']) == 1 and contents['releases'][0]['version'] == version
            and contents['releases'][0]['tag'] == 'v' + version, 'Feed release version/channel differs')
    signature(directory / feed, directory, anchor)


def assets(args, record, feed):
    tag = 'v' + args.version
    release = api(f'repos/{args.repo}/releases/tags/{tag}')
    latest = api(f'repos/{args.repo}/releases/latest')
    require(release['tag_name'] == tag and release['name'] == 'Performance Dashboard ' + tag, 'Release identity differs')
    require(not release['draft'] and not release['prerelease'] and latest['id'] == release['id'], 'Release is not stable Latest')
    require(len(release['assets']) == 7 and {a['name']: a['size'] for a in release['assets']} == record['sizes'], 'Hosted asset inventory differs')
    require(sha(args.notes) == args.notes_sha256, 'Reviewed notes hash differs')
    require(release['body'].encode() == args.notes.read_bytes(), 'Hosted body bytes differ')
    args.evidence.mkdir(parents=True, exist_ok=False)
    dest = args.evidence / 'assets'
    command = ['gh', 'release', 'download', tag, '--repo', args.repo, '--dir', str(dest)]
    for name in sorted(record['files']):
        command.extend(['--pattern', name])
    subprocess.run(command, check=True)  # No clobber; one download, no retry.
    local_assets(dest, record, args.version, args.anchor, args.arch)
    result = dict(status='PASS', version=args.version, arch=args.arch, repo=args.repo,
                  releaseURL=release['html_url'], files=record['files'], sizes=record['sizes'],
                  notesSHA256=args.notes_sha256)
    (args.evidence / 'assets-PASS.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def live_feed(args, record, feed):
    saved = json.loads((args.evidence / 'assets-PASS.json').read_text())
    require(saved['status'] == 'PASS' and saved['version'] == args.version and saved['repo'] == args.repo
            and saved.get('arch', 'x86_64') == args.arch
            and saved['files'] == record['files'] and saved['sizes'] == record['sizes']
            and saved['notesSHA256'] == args.notes_sha256, 'Matching hosted asset PASS required first')
    require(sha(args.notes) == args.notes_sha256, 'Reviewed notes hash differs')
    # Recheck retained bytes/signatures so a stale PASS cannot mask local changes.
    local_assets(args.evidence / 'assets', record, args.version, args.anchor, args.arch)
    require(not (args.evidence / 'feed-PASS.json').exists(), 'Feed already verified; use explicit new evidence')
    request = urllib.request.Request(args.feed_url, headers={'Cache-Control': 'no-cache'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(1024 * 1024 + 1)
    require(len(data) <= 1024 * 1024 and hashlib.sha256(data).hexdigest() == record['files'][feed], 'Live feed bytes differ')
    live = args.evidence / 'live-stable.json'
    with live.open('xb') as stream:
        stream.write(data)
    signature(live, args.evidence / 'assets', args.anchor)
    result = dict(status='PASS', version=args.version, arch=args.arch, url=args.feed_url, SHA256=record['files'][feed])
    (args.evidence / 'feed-PASS.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['assets', 'feed'])
    parser.add_argument('--version', required=True)
    parser.add_argument('--arch', choices=['x86_64', 'aarch64'], default='x86_64')
    parser.add_argument('--record', required=True, type=Path, help='Reviewed files/sizes JSON')
    parser.add_argument('--notes', required=True, type=Path)
    parser.add_argument('--notes-sha256', required=True)
    parser.add_argument('--anchor', required=True, type=Path, help='Reviewed publicEDKey JSON')
    parser.add_argument('--evidence', required=True, type=Path, help='Fresh directory for assets; same directory for feed')
    parser.add_argument('--repo', default='danjboyd/gnustep-performance-dashboard')
    parser.add_argument('--feed-url', default='https://danjboyd.github.io/gnustep-performance-dashboard/updates/linux/stable.json')
    args = parser.parse_args()
    try:
        record, feed = inventory(args.record, args.version, args.arch)
        require(re.fullmatch('[0-9a-f]{64}', args.notes_sha256), 'Invalid notes SHA256')
        result = assets(args, record, feed) if args.phase == 'assets' else live_feed(args, record, feed)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
