#!/usr/bin/env python3
"""Offline mutation checks for hosted verification and the version-literal gate."""
import copy
import hashlib
import importlib.util
import io
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / '.github/scripts' / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


verify = module('hosted_verifier', 'verify-hosted.py')
gate = module('version_literals', 'check-version-literals.py')


class HostedChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pd-hosted-check-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def fixture(self, version, arch='x86_64'):
        names, feed = verify.filenames(version, arch)
        staged = self.work / ('stage-' + version + '-' + arch)
        staged.mkdir()
        for name in names - {'SHA256SUMS'}:
            (staged / name).write_bytes(('synthetic ' + name).encode())
        (staged / feed).write_text(json.dumps(dict(package=dict(version=version), channel='stable',
            releases=[dict(version=version, tag='v' + version)])))
        sums = ''.join(verify.sha(staged / n) + '  ' + n + '\n' for n in sorted(names - {'SHA256SUMS'}))
        (staged / 'SHA256SUMS').write_text(sums)
        record = dict(files={n: verify.sha(staged / n) for n in names}, sizes={n: (staged / n).stat().st_size for n in names})
        record_path = self.work / ('record-' + version + '-' + arch)
        record_path.write_text(json.dumps(record))
        notes = self.work / 'notes.md'
        notes.write_bytes(b'exact reviewed body\n')
        args = SimpleNamespace(version=version, arch=arch, repo='owner/project', evidence=self.work / ('evidence-' + version + '-' + arch),
            notes=notes, notes_sha256=verify.sha(notes), anchor=self.work / 'public.json', feed_url='https://example.invalid/stable.json')
        release = dict(id=1, tag_name='v'+version, name='Performance Dashboard v'+version, draft=False, prerelease=False,
            html_url='https://example.invalid/release', body=notes.read_text(), assets=[dict(name=n, size=record['sizes'][n]) for n in names])
        return args, record, feed, staged, release, record_path

    def publish_checks(self, args, record, feed, staged, release, signature=None):
        def download(command, **kwargs):
            self.assertEqual(command[:3], ['gh', 'release', 'download'])
            self.assertEqual(command[3], 'v' + args.version)
            self.assertNotIn('--clobber', command)
            self.assertEqual(set(command[i+1] for i, value in enumerate(command) if value == '--pattern'), set(record['files']))
            shutil.copytree(staged, Path(command[command.index('--dir')+1]))
        with patch.object(verify, 'api', side_effect=[release, dict(id=release['id'])]), \
             patch.object(verify.subprocess, 'run', side_effect=download), \
             patch.object(verify, 'signature', side_effect=signature) as signed:
            result = verify.assets(args, record, feed)
            self.assertEqual(signed.call_args.args[0].name, feed)
            return result

    def test_versions_derive_every_asset_and_live_feed_lookup(self):
        for version in ('0.1.8', '0.1.9', '0.2.0'):
            args, record, feed, staged, release, path = self.fixture(version)
            self.assertEqual(verify.inventory(path, version), (record, feed))
            self.assertEqual(self.publish_checks(args, record, feed, staged, release)['status'], 'PASS')
            with patch.object(verify, 'signature') as signed, \
                 patch.object(verify.urllib.request, 'urlopen', return_value=io.BytesIO((staged/feed).read_bytes())):
                self.assertEqual(verify.live_feed(args, record, feed)['SHA256'], record['files'][feed])
                self.assertEqual(signed.call_args_list[0].args[0].name, feed)

    def test_aarch64_inventory_assets_and_feed_are_arch_bound(self):
        args, record, feed, staged, release, path = self.fixture('0.2.0', 'aarch64')
        self.assertEqual(verify.inventory(path, args.version, args.arch), (record, feed))
        self.assertIn('-aarch64.update-feed.json', feed)
        with self.assertRaises(ValueError): verify.inventory(path, args.version)
        self.publish_checks(args, record, feed, staged, release)
        with patch.object(verify, 'signature'), patch.object(verify.urllib.request, 'urlopen', return_value=io.BytesIO((staged/feed).read_bytes())):
            self.assertEqual(verify.live_feed(args, record, feed)['arch'], 'aarch64')
        for unsafe in ('../aarch64', 'arm64', 'x86_64/../../bad'):
            with self.assertRaises(ValueError): verify.filenames(args.version, unsafe)

    def test_stale_inventory_and_unsafe_versions_fail_closed(self):
        args, record, feed, staged, release, path = self.fixture('0.1.8')
        with self.assertRaisesRegex(ValueError, 'version-derived'):
            verify.inventory(path, '0.1.9')
        for version in ('../0.1.9', '0.1.9-review', '0.1.9\n'):
            with self.assertRaises(ValueError): verify.filenames(version)

    def test_hash_size_checksum_and_signature_failure_create_no_pass(self):
        for mutation in ('hash', 'size', 'sums', 'feed-version', 'signature'):
            with self.subTest(mutation=mutation):
                args, record, feed, staged, release, path = self.fixture('0.1.' + str(20 + len(list(self.work.glob('stage-*')))))
                if mutation == 'hash':
                    (staged/feed).write_bytes(b'x' * record['sizes'][feed])
                if mutation == 'size':
                    (staged/feed).write_bytes(b'bad')
                if mutation == 'feed-version':
                    data = json.loads((staged/feed).read_text()); data['package']['version'] = 'stale'
                    (staged/feed).write_text(json.dumps(data))
                    record['files'][feed] = verify.sha(staged/feed); record['sizes'][feed] = (staged/feed).stat().st_size
                    sums = staged/'SHA256SUMS'
                    sums.write_text(''.join(record['files'][n] + '  ' + n + '\n' for n in sorted(record['files']) if n != 'SHA256SUMS'))
                    record['files']['SHA256SUMS'] = verify.sha(sums); record['sizes']['SHA256SUMS'] = sums.stat().st_size
                if mutation == 'sums':
                    sums = staged/'SHA256SUMS'; sums.write_text(sums.read_text() + sums.read_text().splitlines()[0] + '\n')
                    record['files']['SHA256SUMS'] = verify.sha(sums); record['sizes']['SHA256SUMS'] = sums.stat().st_size
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    self.publish_checks(args, record, feed, staged, release,
                        subprocess.CalledProcessError(1, ['signature', '--verify']) if mutation == 'signature' else None)
                self.assertFalse((args.evidence/'assets-PASS.json').exists())

    def test_body_latest_and_version_metadata_refuse_before_download(self):
        args, record, feed, staged, release, path = self.fixture('0.1.9')
        for field, value in [('body', 'changed'), ('draft', True), ('prerelease', True), ('tag_name', 'old')]:
            bad = dict(release, **{field:value})
            with patch.object(verify, 'api', side_effect=[bad, dict(id=1)]), patch.object(verify.subprocess, 'run') as download:
                with self.assertRaises(ValueError): verify.assets(args, record, feed)
                download.assert_not_called()
        with patch.object(verify, 'api', side_effect=[release, dict(id=2)]):
            with self.assertRaises(ValueError): verify.assets(args, record, feed)
        self.assertFalse(args.evidence.exists())

    def test_stale_pass_live_mismatch_and_modified_retained_bytes_refuse(self):
        args, record, feed, staged, release, path = self.fixture('0.1.9')
        with self.assertRaises(FileNotFoundError): verify.live_feed(args, record, feed)
        self.publish_checks(args, record, feed, staged, release)
        with patch.object(verify, 'signature'), patch.object(verify.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')):
            with self.assertRaisesRegex(ValueError, 'Live feed bytes'): verify.live_feed(args, record, feed)
        self.assertFalse((args.evidence/'feed-PASS.json').exists())
        changed = copy.deepcopy(record); changed['files'][feed] = '0'*64
        with self.assertRaisesRegex(ValueError, 'Matching hosted asset PASS'): verify.live_feed(args, changed, feed)
        (args.evidence/'assets'/feed).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Asset bytes'): verify.live_feed(args, record, feed)

    def test_signature_command_is_verify_only_and_drops_private_environment(self):
        anchor = self.work/'public.json'; anchor.write_text(json.dumps(dict(publicEDKey='public-only')))
        with patch.dict(verify.os.environ, {'UPDATE_ED_PRIVATE_KEY':'test-only-sentinel'}), patch.object(verify.subprocess, 'run') as run:
            verify.signature(self.work/'feed.json', self.work, anchor)
        self.assertIn('--verify', run.call_args.args[0])
        self.assertEqual(set(run.call_args.kwargs['env']), {'PATH', 'UPDATE_ED_PUBLIC_KEY'})


class GateChecks(unittest.TestCase):
    def test_dependency_pin_is_shared_and_part_of_sdk_cache_identity(self):
        pins = ROOT / 'docs/ci-source-pins.env'
        install = (ROOT / '.github/scripts/install-gnustep.sh').read_text()
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('XCTEST_TAG=', pins.read_text())
        self.assertIn('docs/ci-source-pins.env', install)
        self.assertIn('. docs/ci-source-pins.env', workflow)
        self.assertEqual(workflow.count("hashFiles('.github/scripts/install-gnustep.sh', 'docs/ci-source-pins.env')"), 3)
        self.assertIn('--branch "$XCTEST_TAG"', workflow)

    def test_dispatch_versions_are_explicit_and_required(self):
        for name in ('csd-review.yml', 'assemble-candidate.yml', 'windows-package.yml'):
            body = (ROOT / '.github/workflows' / name).read_text()
            block = re.search(r'^      version:\n((?:        .*\n)*)', body, re.M).group(1)
            self.assertIn('required: true', block)
            self.assertNotIn('default:', block)
        windows = (ROOT / '.github/workflows/windows-package.yml').read_text()
        self.assertNotIn('inputs.version ||', windows)
        self.assertIn("$env:GITHUB_EVENT_NAME -ne 'push'", windows)
        self.assertIn('(Get-Content package.version -Raw).Trim()', windows)

    def test_real_tree_and_mutations(self):
        gate.check(ROOT)
        with tempfile.TemporaryDirectory(prefix='pd-literal-gate-') as temp:
            root = Path(temp)
            for directory in ('.github/scripts', '.github/workflows', 'docs'): (root/directory).mkdir(parents=True)
            allow = root/'docs/ci-version-literals.allowlist.json'; allow.write_text('[]')
            target = root/'.github/scripts/test.py'
            for literal in ('v0.1.9', 'v0.2.0', 'v0.15.42', 'v019', 'PerformanceDashboard-0.1.8-x86_64.update-feed.json', 'PerformanceDashboard-0.15.42-aarch64.AppImage'):
                target.write_text('file="'+literal+'"\n')
                with self.assertRaises(ValueError): gate.check(root)
            target.write_text('file="docs/v019-baseline.json"\n')
            allow.write_text(json.dumps([dict(file='.github/scripts/test.py', literal='docs/v019-baseline.json', count=1, reason='Immutable documentation baseline')]))
            gate.check(root)
            target.write_text(target.read_text()+'selected="v0.1.8"\n')
            with self.assertRaises(ValueError): gate.check(root)
            target.write_text('none=1\n')
            with self.assertRaisesRegex(ValueError, 'Stale documentation'): gate.check(root)
            allow.write_text(json.dumps([dict(file='.github/scripts/test.py', literal='packaging/v019.json', count=1, reason='bad exception')]))
            with self.assertRaisesRegex(ValueError, 'Only explicit documented'): gate.check(root)


if __name__ == '__main__':
    unittest.main()
