#!/usr/bin/env python3
"""Synthetic custom source collection: no SDK, network, apt or compilation."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('collector', ROOT / 'scripts/collect-release-sources.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CustomSources(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        shutil.copytree(ROOT / 'packaging', self.root / 'packaging')
        for name in ('docs/proposals/csd-theme-defaults.patch', 'scripts/package-stage.sh'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        self.lock_path = self.root / 'packaging/linux/v017-custom-toolchain.lock.proposed.json'
        self.lock = json.loads(self.lock_path.read_text())
        self.provenance = dict(schema_version=1, kind='custom-gnustep-toolchain-provenance',
            official=False, install_domain='LOCAL', lock={'sha256': collector.check.digest(self.lock_path)},
            components=[dict(name=c['name'], url=c['url'], revision=c['revision'],
                resolved_commit=c['revision'], configure_args=c.get('configure_args', []),
                applied_patches=c.get('patches', [])) for c in self.lock['components']])
        self.provenance_path = self.root / 'sdk.json'
        self.save_provenance()
        self.args = SimpleNamespace(version='0.1.7', custom_lock=self.lock_path,
            sdk_provenance=self.provenance_path, builder_source=self.root / 'builder',
            work=self.root / 'work', output=self.root / 'sources.tar.gz')
        self.addCleanup(patch.stopall)
        patch.object(collector, 'root', self.root).start()
        self.network = patch.object(collector.urllib.request, 'urlopen',
            side_effect=AssertionError('unexpected network')).start()
        patch.object(collector, 'git', side_effect=self.fake_git).start()

    def save_provenance(self):
        self.provenance_path.write_text(json.dumps(self.provenance))

    def fake_git(self, directory, *args):
        if args[0] == 'rev-parse':
            return collector.BUILDER
        if args[0] == 'status':
            return ''
        self.assertEqual(args[0], 'archive')
        Path(args[args.index('-o') + 1]).write_bytes(b'synthetic builder archive')
        return ''

    def test_positive_complete_synthetic_archive(self):
        payload = b'synthetic source archive'
        pin = self.root / 'packaging/linux/robin-map-source.json'
        value = json.loads(pin.read_text())
        value['archiveSHA256'] = hashlib.sha256(payload).hexdigest()
        pin.write_text(json.dumps(value))
        licenses = self.root / 'dist/stage/metadata/licenses/host-libraries.txt'
        licenses.parent.mkdir(parents=True)
        licenses.write_text('')  # No distribution libraries in this synthetic fixture.
        self.network.side_effect = lambda url: io.BytesIO(payload)
        def archive_app(command, **kwargs):
            self.assertEqual(command[:2], ['git', 'archive'])
            Path(command[command.index('-o') + 1]).write_bytes(b'synthetic app archive')
        with patch.object(collector.subprocess, 'run', side_effect=archive_app), contextlib.redirect_stdout(io.StringIO()):
            collector.collect(self.args)
        with tarfile.open(self.args.output) as archive:
            prefix = 'PerformanceDashboard-0.1.7-sources/'
            names = archive.getnames()
            inventory = json.loads(archive.extractfile(prefix + 'sources.json').read())
            self.assertEqual(len(inventory), 15)
            for component in self.lock['components']:
                self.assertIn(prefix + component['name'] + '-' + component['revision'] + '.tar.gz', names)
                for entry in component['patches']:
                    data = archive.extractfile(prefix + 'custom-sdk/' + entry['path']).read()
                    self.assertEqual(hashlib.sha256(data).hexdigest(), entry['sha256'])
            for name in (self.lock_path.name, 'v017-review-inputs.json', 'gnustep-toolchain-provenance.json',
                         'application/docs/proposals/csd-theme-defaults.patch', 'application/scripts/package-stage.sh'):
                self.assertIn(prefix + 'custom-sdk/' + name, names)
            note = archive.extractfile(prefix + 'custom-sdk/APPLYING-PATCHES.txt').read()
            self.assertIn(b'already applied', note)
            self.assertIn(prefix + 'gnustep-cli-new-' + collector.BUILDER + '.tar.gz', names)
            for line in archive.extractfile(prefix + 'SHA256SUMS').read().decode().splitlines():
                digest, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256(archive.extractfile(prefix + name).read()).hexdigest(), digest)

    def test_numeric_collection_refuses_wrong_version_or_managed_producer(self):
        self.args.version = '0.1.8'
        with self.assertRaisesRegex(ValueError, 'package.version'):
            collector.collect(self.args)
        self.args.version = '0.1.7'
        config = self.root / 'packaging/linux/release-production.json'
        config.write_text(json.dumps({'schemaVersion': 1, 'linuxProducer': 'managed'}))
        with self.assertRaisesRegex(ValueError, 'Custom producer'):
            collector.collect(self.args)
        self.network.assert_not_called()
        self.assertFalse(self.args.work.exists())

    def test_wrong_lock(self):
        self.provenance['lock']['sha256'] = '0' * 64
        self.save_provenance()
        with self.assertRaisesRegex(ValueError, 'SDK lock mismatch'):
            collector.select_custom(self.args)

    def test_wrong_revision(self):
        self.provenance['components'][0]['resolved_commit'] = '0' * 40
        self.save_provenance()
        with self.assertRaisesRegex(ValueError, 'revision/patch'):
            collector.select_custom(self.args)

    def test_missing_altered_and_reordered_patch(self):
        entry = self.lock['components'][3]['patches'][0]
        path = self.lock_path.parent / entry['path']
        original = path.read_bytes()
        for mode in ('missing', 'altered'):
            with self.subTest(mode=mode):
                path.unlink() if mode == 'missing' else path.write_bytes(b'altered')
                with self.assertRaises((OSError, ValueError)):
                    collector.select_custom(self.args)
                path.write_bytes(original)
        self.provenance['components'][3]['applied_patches'].reverse()
        self.save_provenance()
        with self.assertRaisesRegex(ValueError, 'revision/patch'):
            collector.select_custom(self.args)

    def test_builder_mismatch(self):
        with patch.object(collector, 'git', side_effect=lambda directory, *args:
                '0' * 40 if args[0] == 'rev-parse' else ''):
            with self.assertRaisesRegex(ValueError, 'builder identity'):
                collector.select_custom(self.args)

    def test_staged_provenance_mismatch(self):
        marker = self.root / 'dist/stage/metadata/custom-toolchain-lock.json'
        marker.parent.mkdir(parents=True)
        shutil.copy2(self.lock_path, marker)
        marker.with_name('custom-toolchain-provenance.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'staged SDK provenance'):
            collector.select_custom(self.args)
        self.network.assert_not_called()

    def test_stale_work_or_output(self):
        for path in (self.args.work, self.args.output):
            with self.subTest(path=path):
                path.write_text('preserve me')
                with self.assertRaisesRegex(ValueError, 'stale output'):
                    collector.collect(self.args)
                self.assertEqual(path.read_text(), 'preserve me')
                path.unlink()
        self.network.assert_not_called()

    def test_custom_candidate_refuses_generic_and_incomplete_mode(self):
        marker = self.root / 'dist/stage/metadata/custom-toolchain-lock.json'
        marker.parent.mkdir(parents=True)
        marker.write_text('{}')
        args = copy.copy(self.args)
        args.custom_lock = args.sdk_provenance = args.builder_source = None
        with self.assertRaisesRegex(ValueError, 'refuses default home-directory'):
            collector.select_custom(args)
        args.custom_lock = self.lock_path
        with self.assertRaisesRegex(ValueError, 'requires lock'):
            collector.select_custom(args)


if __name__ == '__main__':
    unittest.main()
