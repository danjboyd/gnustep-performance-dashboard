#!/usr/bin/env python3
"""Offline corresponding-source fixtures; no downloads, compiler or SDK/app run."""
import copy
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('csd_sources', ROOT / 'scripts/verify-csd-sources.py')
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)
COMMIT = 'c' * 40


def tiny_archive(path, cmake=None):
    with tarfile.open(path, 'w:gz') as archive:
        data = b'synthetic source fixture only'
        member = tarfile.TarInfo('synthetic/README')
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
        if cmake is not None:
            member = tarfile.TarInfo('synthetic/CMakeLists.txt')
            member.size = len(cmake)
            archive.addfile(member, io.BytesIO(cmake))


class CSDSourceChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pd-csd-source-unit-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.tree = self.root / 'bundle'
        self.tree.mkdir()
        self.config = source.policy.load(ROOT / 'packaging/linux/csd-ci-inputs.json')
        lock_path = ROOT / self.config['lock']
        self.lock = source.policy.load(lock_path)
        self.lock_sha = source.policy.sha(lock_path)
        paths = [self.config['lock'], 'packaging/release-inputs.json', 'packaging/linux/csd-ci-inputs.json',
                 'packaging/linux/csd-v7/backports.json', self.config['reviewInputs'], 'packaging/linux/robin-map-source.json']
        review = source.policy.load(ROOT / self.config['reviewInputs'])
        for patch in review['applicationPatches']:
            paths += [patch['path'], patch['appliedSource']['path']]
        paths += ['packaging/linux/' + p['path'] for c in self.lock['components'] for p in c.get('patches', [])]
        for relative in paths:
            (self.project / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.project / relative)
        fallback = self.config['fallbackSource']
        build_sources = dict(schemaVersion=1, gitSources=[dict(fallback, resolvedCommit=fallback['revision'])])
        records = source.git_sources(self.project, self.lock, build_sources)
        cmake = fallback['upstreamBuildDescription']['recordedExcerpt'].encode()
        fallback['upstreamBuildDescription']['sha256'] = hashlib.sha256(cmake).hexdigest()
        for item in records:
            archive = self.tree / item['archiveFile']
            archive.parent.mkdir(exist_ok=True)
            tiny_archive(archive, cmake if item['name'] == 'libobjc2' else None)
            item['archiveSHA256'] = source.policy.sha(archive)
            if item['name'] == 'robin-map-fallback':
                fallback['archiveSHA256'] = item['archiveSHA256']
        build_sources = dict(schemaVersion=1, gitSources=[dict(fallback, resolvedCommit=fallback['revision'])])
        self.config['fallbackSource'] = fallback
        (self.project / 'packaging/linux/csd-ci-inputs.json').write_text(json.dumps(self.config))
        (self.project / 'packaging/linux/robin-map-source.json').write_text(json.dumps(fallback))
        copy_lock = 'custom-toolchain-lock/' + lock_path.name
        (self.tree / copy_lock).parent.mkdir(parents=True)
        shutil.copy2(lock_path, self.tree / copy_lock)
        patches = []
        for component in self.lock['components']:
            for patch in component.get('patches', []):
                relative = 'custom-toolchain-lock/' + patch['path']
                (self.tree / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(lock_path.parent / patch['path'], self.tree / relative)
                patches.append(dict(component=component['name'], lockPath=patch['path'], sha256=patch['sha256'],
                    file=relative, applicationPath='packaging/linux/' + patch['path']))
        index_path = 'custom-toolchain-lock/csd-v7/backports.json'
        shutil.copy2(ROOT / 'packaging/linux/csd-v7/backports.json', self.tree / index_path)
        with tarfile.open(self.tree / 'PerformanceDashboard.tar', 'w', format=tarfile.PAX_FORMAT,
                          pax_headers={'comment': COMMIT}) as archive:
            for file in self.project.rglob('*'):
                if file.is_file():
                    archive.add(file, arcname='PerformanceDashboard/' + str(file.relative_to(self.project)))
        metadata = self.tree / 'metadata'
        metadata.mkdir()
        sdk = dict(official=False, lock=dict(sha256=self.lock_sha), components=[dict(c,
                   resolved_commit=c['revision'], applied_patches=c.get('patches', [])) for c in self.lock['components']])
        (metadata / 'gnustep-toolchain-provenance.json').write_text(json.dumps(sdk))
        (metadata / 'pd-csd-build-sources.json').write_text(json.dumps(build_sources))
        inputs = source.policy.load(ROOT / 'packaging/release-inputs.json')
        receipt = dict(themeSourceRevision=inputs['adwaita']['revision'], toolchainLockSHA256=self.lock_sha,
                       toolchainProvenanceSHA256=source.policy.sha(metadata / 'gnustep-toolchain-provenance.json'))
        (metadata / 'theme-receipt.json').write_text(json.dumps(receipt))
        (metadata / 'container-inputs.json').write_text(json.dumps(dict(builderCommit=self.config['builder']['revision'])))
        (metadata / 'pd-csd-cache-receipt.json').write_text(json.dumps(dict(
            sdkProvenanceSHA256=source.policy.sha(metadata / 'gnustep-toolchain-provenance.json'),
            buildSourcesSHA256=source.policy.sha(metadata / 'pd-csd-build-sources.json'))))
        (metadata / 'host-libraries.txt').write_text('runtime/lib/libfixture.so\tlibfixture1\t1.0\n')
        debian = self.tree / 'debian'
        debian.mkdir()
        tiny_archive(debian / 'fixture_1.0.orig.tar.gz')
        file = debian / 'fixture_1.0.orig.tar.gz'
        (debian / 'fixture_1.0.dsc').write_text('Source: fixture\nVersion: 1.0\nChecksums-Sha256:\n '
            + source.policy.sha(file) + ' ' + str(file.stat().st_size) + ' ' + file.name + '\n')
        self.manifest = dict(schemaVersion=1, applicationCommit=COMMIT, applicationLockPath=self.config['lock'],
            customToolchainLockSHA256=self.lock_sha, lockFile=copy_lock, gitSources=records, patches=patches,
            themeSource=dict(inputs['adwaita'], name='adwaita'),
            builderSource=dict(self.config['builder'], name='gnustep-cli-new'),
            packagerSource=dict(inputs['gnustep-packager'], name='gnustep-packager'), fallbackSource=fallback,
            publicBackportIndex=dict(file=index_path, sha256=source.policy.sha(self.tree / index_path)),
            distributionSources=[dict(name='fixture', revision='1.0')],
            distributionBinaries=[dict(package='libfixture1', source='fixture', revision='1.0')])
        self.save()

    def save(self):
        (self.tree / 'sources.json').write_text(json.dumps(self.manifest))
        source.write_checksums(self.tree)

    def verify(self):
        return source.verify_tree(self.tree, COMMIT, self.lock_sha)

    def test_complete_synthetic_archive_has_16_sdk_patches_and_exact_theme_builder_fallback(self):
        result = self.verify()
        self.assertEqual(result['patchCount'], 16)
        self.assertEqual(result['gitSourceCount'], 14)
        by_name = {value['name']: value for value in self.manifest['gitSources']}
        self.assertEqual(by_name['adwaita']['revision'], self.manifest['themeSource']['revision'])
        self.assertEqual(by_name['gnustep-cli-new']['revision'], self.config['builder']['revision'])
        self.assertEqual(by_name['robin-map-fallback']['revision'], self.config['fallbackSource']['revision'])
        archive = self.root / 'sources.tar.gz'
        with tarfile.open(archive, 'w:gz') as target:
            target.add(self.tree, arcname='sources')
        self.assertTrue(source.verify_bundle(archive, COMMIT, self.lock_sha)['ok'])

    def test_shared_collector_handoff_preserves_strong_fourteen_source_receipt(self):
        spec = importlib.util.spec_from_file_location('shared_core', ROOT / 'scripts/collect-release-sources.py')
        core = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(core)
        work = self.root / 'shared-work'
        work.mkdir()
        for entry in self.manifest['gitSources']:
            shutil.copy2(self.tree / entry['archiveFile'], work / (entry['name'] + '-' + entry['revision'] + '.tar.gz'))
        shutil.copy2(self.tree / 'PerformanceDashboard.tar', work / 'PerformanceDashboard.tar')
        shutil.copytree(self.tree / 'debian', work / 'debian')
        shutil.copytree(self.tree / 'custom-toolchain-lock', work / 'custom-sdk')
        licenses = self.project / 'dist/stage/metadata/licenses'
        licenses.mkdir(parents=True)
        shutil.copy2(self.tree / 'metadata/host-libraries.txt', licenses / 'host-libraries.txt')
        custom = {'provenance_path': self.tree / 'metadata/gnustep-toolchain-provenance.json'}
        with patch.object(core, 'root', self.project), patch.object(core, 'git', return_value=COMMIT), \
             patch.object(core, 'evidence_module', return_value=source), \
             patch.object(core.subprocess, 'check_output', return_value='fixture\t1.0'):
            verifier, commit = core.finish_evidence(custom, work, self.tree / 'metadata')
        verifier.write_checksums(work)
        result = verifier.verify_tree(work, commit, self.lock_sha)
        self.assertEqual(result['gitSourceCount'], 14)
        self.assertEqual(result['patchCount'], 16)
        self.assertEqual(result['applicationCommit'], COMMIT)
        # The compatibility CLI must delegate, not acquire any sources itself.
        wrapper = (ROOT / 'scripts/collect-csd-sources.py').read_text()
        self.assertIn('core.collect(', wrapper)
        self.assertNotIn('urlopen', wrapper)
        self.assertNotIn('apt-get', wrapper)
        self.assertIn('custom-sdk/', (work / 'sources.json').read_text())

    def test_fallback_pinned_archive_mismatch_refused(self):
        self.manifest['fallbackSource']['archiveSHA256'] = '0' * 64
        self.save()
        with self.assertRaisesRegex(ValueError, 'fallback archive pin mismatch'):
            self.verify()

    def test_cmake_evidence_changed_refused(self):
        self.manifest['fallbackSource']['upstreamBuildDescription']['sha256'] = '0' * 64
        self.save()
        with self.assertRaisesRegex(ValueError, 'CMake evidence changed'):
            self.verify()

    def test_applied_application_source_change_in_archive_refused(self):
        review = source.policy.load(self.project / self.config['reviewInputs'])
        applied = review['applicationPatches'][0]['appliedSource']['path']
        (self.project / applied).write_text('changed source fixture')
        with tarfile.open(self.tree / 'PerformanceDashboard.tar', 'w', format=tarfile.PAX_FORMAT,
                          pax_headers={'comment': COMMIT}) as archive:
            for file in self.project.rglob('*'):
                if file.is_file():
                    archive.add(file, arcname='PerformanceDashboard/' + str(file.relative_to(self.project)))
        self.save()
        with self.assertRaisesRegex(ValueError, 'applied application source differs'):
            self.verify()

    def test_missing_theme_source_refused(self):
        self.manifest['gitSources'] = [v for v in self.manifest['gitSources'] if v['name'] != 'adwaita']
        self.save()
        with self.assertRaisesRegex(ValueError, 'corresponding source: adwaita'):
            self.verify()

    def test_csd_patch_missing_or_changed_refused(self):
        patch = next(v for v in self.manifest['patches'] if 'csd-v7' in v['lockPath'])
        (self.tree / patch['file']).write_bytes(b'changed patch')
        self.save()
        with self.assertRaisesRegex(ValueError, 'patch bytes differ'):
            self.verify()

    def test_wrong_app_commit_or_lock_refused(self):
        with self.assertRaisesRegex(ValueError, 'application source commit mismatch'):
            source.verify_tree(self.tree, 'f' * 40, self.lock_sha)
        with self.assertRaisesRegex(ValueError, 'source lock digest mismatch'):
            source.verify_tree(self.tree, COMMIT, '0' * 64)

    def test_fallback_record_cannot_silently_use_old_tag(self):
        self.manifest['fallbackSource'] = dict(self.manifest['fallbackSource'], revision='d' * 40)
        self.save()
        with self.assertRaisesRegex(ValueError, 'corresponding source: robin-map-fallback'):
            self.verify()

    def test_theme_receipt_or_builder_identity_missing_refused(self):
        (self.tree / 'metadata/theme-receipt.json').unlink()
        self.save()
        with self.assertRaises(OSError):
            self.verify()

    def test_debian_original_source_missing_refused(self):
        (self.tree / 'debian/fixture_1.0.orig.tar.gz').unlink()
        self.save()
        with self.assertRaises(OSError):
            self.verify()

    def test_manifest_path_escape_and_incomplete_checksum_inventory_refused(self):
        self.manifest['lockFile'] = '../outside'
        self.save()
        with self.assertRaisesRegex(ValueError, 'unsafe manifest path'):
            self.verify()
        self.manifest['lockFile'] = 'custom-toolchain-lock/v017-custom-toolchain.lock.proposed.json'
        self.save()
        lines = (self.tree / 'SHA256SUMS').read_text().splitlines()
        (self.tree / 'SHA256SUMS').write_text('\n'.join(lines[:-1]) + '\n')
        with self.assertRaisesRegex(ValueError, 'checksum inventory incomplete'):
            self.verify()

    def test_structured_receipt_is_separate_from_collection_stdout_and_never_clobbers(self):
        receipt = self.root / 'collection-proof.json'
        result = dict(ok=True, applicationCommit=COMMIT)
        wrapper_spec = importlib.util.spec_from_file_location('source_wrapper', ROOT / 'scripts/collect-csd-sources.py')
        wrapper = importlib.util.module_from_spec(wrapper_spec)
        wrapper_spec.loader.exec_module(wrapper)
        def collect(*args):
            print('synthetic apt progress: not JSON')
            return result
        args = ['collect-csd-sources.py', '--version', '0.1.7-review', '--output', str(self.root / 'output'),
                '--receipt-output', str(receipt)]
        with patch.object(source.sys, 'argv', args), \
             patch.dict(source.os.environ, GNUSTEP_CLI_ROOT=str(self.root)), \
             patch.object(wrapper, 'collect', side_effect=collect), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertIsNone(wrapper.main())
            self.assertIn('not JSON', output.getvalue())
            self.assertEqual(json.loads(receipt.read_text()), result)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                wrapper.main()
            self.assertEqual(json.loads(receipt.read_text()), result)

    def test_outer_tar_path_escape_refused_without_extraction(self):
        archive = self.root / 'unsafe.tar.gz'
        with tarfile.open(archive, 'w:gz') as target:
            member = tarfile.TarInfo('../outside')
            member.size = 1
            target.addfile(member, io.BytesIO(b'x'))
        with self.assertRaisesRegex(ValueError, 'unsafe source bundle path'):
            source.verify_bundle(archive, COMMIT, self.lock_sha)
        self.assertFalse((self.root / 'outside').exists())


if __name__ == '__main__':
    unittest.main()
