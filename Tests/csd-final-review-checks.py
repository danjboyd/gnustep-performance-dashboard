#!/usr/bin/env python3
"""Offline final-artifact refusal tests. Synthetic bytes; no AppImage execution."""
import copy
import io
import tarfile
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('csd_final', ROOT / '.github/scripts/csd-review-final.py')
final = importlib.util.module_from_spec(spec)
spec.loader.exec_module(final)
p = final.policy
VERSION = '0.1.7-review'
BASE = 'PerformanceDashboard-' + VERSION + '-x86_64'
COMMIT = 'a' * 40


class FinalReviewChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pd-final-policy-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.packages = self.root / 'packages'
        self.packages.mkdir()
        for name in final.names(VERSION):
            (self.packages / name).write_bytes(b'synthetic artifact ' + name.encode())
        self.directory = self.root / 'review'
        final.prepare(self.packages, self.directory, VERSION)
        self.source = 'PerformanceDashboard-' + VERSION + '-sources.tar.gz'
        (self.directory / self.source).write_bytes(b'synthetic source archive')
        self.lock = self.root / 'lock.json'
        self.lock.write_text('{}')
        (self.root / 'review-inputs.json').write_text('{}')
        self.container = dict(builderCommit='b' * 40, reviewImageID='sha256:' + 'c' * 64, cacheIdentity='d' * 64)
        self.theme = dict(themeBinarySHA256='e' * 64)
        self.cache = dict(lockSHA256=p.sha(self.lock), sdkProvenanceSHA256='f' * 64,
                          backendBuildLogSHA256='1' * 64, buildSourcesSHA256='4' * 64, cacheKey='exact-cache', buildContainerInputs=self.container)
        self.provenance = dict(kind='performance-dashboard-custom-csd-review-provenance', version=VERSION,
            commit=COMMIT, sourceDirty=False, inputs=dict(customToolchain=dict(lockSHA256=p.sha(self.lock),
                sdkProvenanceSHA256='f' * 64), adwaita=dict(buildReceipt=self.theme)))
        self.provenance.update(applicationPayload={'app/test': dict(sha256='2' * 64)},
            payloadIdentityChecks={'adwaita': dict(payload=dict(sha256='3' * 64))})
        self.write(BASE + '.provenance.json', self.provenance)
        app = self.directory / (BASE + '.AppImage')
        zsync = self.directory / (BASE + '.AppImage.zsync')
        self.asset = dict(name=app.name, **final.file_record(app), zsync=dict(name=zsync.name, **final.file_record(zsync)))
        self.feed = dict(package=dict(version=VERSION), releases=[dict(version=VERSION, assets=[self.asset])])
        self.write(BASE + '.update-feed.json', self.feed)
        self.metadata = dict(package=dict(version=VERSION), artifacts={field: dict(path=str(file), **final.file_record(file))
            for field, file in [('appImage', app), ('zsync', zsync), ('updateFeed', self.directory / (BASE + '.update-feed.json'))]})
        self.write(BASE + '.metadata.json', self.metadata)
        self.themes = dict(schema=1, package=dict(version=VERSION),
            appimage=dict(fileName=app.name, **final.file_record(app)))
        self.write(BASE + '.themes.json', self.themes)
        self.write('container-inputs.json', self.container)
        self.write('pd-csd-cache-receipt.json', self.cache)
        self.write('theme-receipt.json', self.theme)
        self.write('backend-closure.json', dict(unexpected=[], backendBuildLogSHA256='1' * 64))
        self.write('payload-closure.json', dict(appImage=final.file_record(app),
            provenanceSHA256=p.sha(self.directory / (BASE + '.provenance.json')),
            selectedPayloadSHA256={'app/test': '2' * 64, 'runtime/System/Library/Themes/Adwaita.theme/Adwaita': '3' * 64}, closure=dict(elfCount=2)))
        self.source_proof = dict(ok=True, applicationCommit=COMMIT, customToolchainLockSHA256=p.sha(self.lock))
        self.write('sources-verification.json', self.source_proof)
        if getattr(self, 'use_real_gates', False):
            return
        for target, kwargs in [
            (p, dict(attribute='settings', return_value=({'reviewInputs': 'review-inputs.json'}, self.lock, {}))),
            (p, dict(attribute='cache_key', return_value='exact-cache')),
            (final, dict(attribute='verify_sources', return_value=self.source_proof)),
            (p.subprocess, dict(attribute='check_output', side_effect=lambda command, **kw: COMMIT if command[-1] == 'HEAD' else '')),
        ]:
            mock = patch.object(target, **kwargs)
            mock.start()
            self.addCleanup(mock.stop)

    def write(self, name, data):
        (self.directory / name).write_text(json.dumps(data))

    def receipt(self):
        record = final.inventory(self.root, self.directory, VERSION)
        (self.directory / final.RECEIPT).write_text(final.canonical(record))
        return record

    def test_positive_canonical_aggregate_covers_all_fourteen_files(self):
        record = self.receipt()
        self.assertEqual(len(record['files']), 14)
        self.assertEqual(record['applicationCommit'], COMMIT)
        self.assertEqual(record['reviewImageID'], self.container['reviewImageID'])
        self.assertRegex(final.verify_receipt(self.root, self.directory, VERSION), r'^[0-9a-f]{64}$')

    def test_theme_sidecar_binds_the_exact_appimage_and_version(self):
        for field, bad in [('fileName', 'other.AppImage'), ('sha256', '0' * 64), ('sizeBytes', 1)]:
            changed = copy.deepcopy(self.themes)
            changed['appimage'][field] = bad
            self.write(BASE + '.themes.json', changed)
            with self.assertRaisesRegex(ValueError, 'theme sidecar bytes/version'):
                self.receipt()
        changed = copy.deepcopy(self.themes)
        changed['package']['version'] = '0.0.0'
        self.write(BASE + '.themes.json', changed)
        with self.assertRaisesRegex(ValueError, 'theme sidecar bytes/version'):
            self.receipt()

    def test_numeric_unsigned_receipt_still_binds_exact_source_commit(self):
        with patch.dict(globals(), VERSION='0.1.7', BASE='PerformanceDashboard-0.1.7-x86_64'):
            self.setUp()
            record = self.receipt()
            self.assertEqual(record['version'], '0.1.7')
            self.assertEqual(record['applicationCommit'], COMMIT)
            self.assertEqual(len(record['files']), 14)
            self.provenance['commit'] = 'b' * 40
            self.write(BASE + '.provenance.json', self.provenance)
            with self.assertRaisesRegex(ValueError, 'version/commit/clean-source'):
                final.verify_receipt(self.root, self.directory, VERSION)

    def test_missing_source_and_extra_versions_refuse(self):
        for name in ('PerformanceDashboard-0.1.6-sources.tar.gz', 'PerformanceDashboard-0.1.7-review.1-x86_64.AppImage', 'unexplained.json'):
            file = self.directory / name
            file.write_bytes(b'extra')
            with self.assertRaisesRegex(ValueError, 'extra or missing'):
                final.inventory(self.root, self.directory, VERSION)
            file.unlink()
        (self.directory / self.source).unlink()
        with self.assertRaisesRegex(ValueError, 'extra or missing'):
            final.inventory(self.root, self.directory, VERSION)

    def test_prepare_creates_missing_parent_but_never_replaces_output(self):
        output = self.root / 'fresh/dist/ci/csd-review'
        self.assertFalse(output.parent.exists())
        final.prepare(self.packages, output, VERSION)
        self.assertEqual({p.name for p in output.iterdir()}, final.names(VERSION))
        before = {p.name: p.read_bytes() for p in output.iterdir()}
        with self.assertRaises(FileExistsError):
            final.prepare(self.packages, output, VERSION)
        self.assertEqual({p.name: p.read_bytes() for p in output.iterdir()}, before)

    def test_prepare_refuses_stale_package_or_existing_output(self):
        with self.assertRaises(FileExistsError):
            final.prepare(self.packages, self.directory, VERSION)
        (self.packages / 'PerformanceDashboard-0.1.6-x86_64.AppImage').write_bytes(b'stale')
        with self.assertRaisesRegex(ValueError, 'extra or missing'):
            final.prepare(self.packages, self.root / 'fresh', VERSION)

    def test_symlink_sidecar_refuses(self):
        file = self.directory / 'backend-closure.json'
        file.unlink()
        file.symlink_to(self.lock)
        with self.assertRaisesRegex(ValueError, 'without symlinks'):
            final.inventory(self.root, self.directory, VERSION)

    def test_changed_final_appimage_refuses_extraction_binding(self):
        (self.directory / (BASE + '.AppImage')).write_bytes(b'changed after extraction')
        with self.assertRaisesRegex(ValueError, 'extraction AppImage/provenance'):
            final.inventory(self.root, self.directory, VERSION)

    def test_stale_provenance_and_feed_refuse(self):
        self.provenance['commit'] = '0' * 40
        self.write(BASE + '.provenance.json', self.provenance)
        with self.assertRaisesRegex(ValueError, 'provenance version/commit'):
            final.inventory(self.root, self.directory, VERSION)
        self.provenance['commit'] = COMMIT
        self.write(BASE + '.provenance.json', self.provenance)
        self.feed['releases'][0]['assets'][0]['sha256'] = '0' * 64
        self.write(BASE + '.update-feed.json', self.feed)
        with self.assertRaisesRegex(ValueError, 'feed bytes'):
            final.inventory(self.root, self.directory, VERSION)

    def test_signed_review_asset_refuses(self):
        self.feed['releases'][0]['assets'][0]['edSignature'] = 'unexpected-signature'
        self.write(BASE + '.update-feed.json', self.feed)
        with self.assertRaisesRegex(ValueError, 'unexpectedly signed'):
            final.inventory(self.root, self.directory, VERSION)

    def test_changed_source_or_noncanonical_receipt_refuses_readback(self):
        self.receipt()
        (self.directory / self.source).write_bytes(b'changed source bytes')
        with self.assertRaisesRegex(ValueError, 'canonical aggregate'):
            final.verify_receipt(self.root, self.directory, VERSION)
        (self.directory / self.source).write_bytes(b'synthetic source archive')
        file = self.directory / final.RECEIPT
        file.write_text(json.dumps(json.loads(file.read_text()), indent=2))
        with self.assertRaisesRegex(ValueError, 'canonical aggregate'):
            final.verify_receipt(self.root, self.directory, VERSION)

    def test_source_verification_failure_is_fatal(self):
        with patch.object(final, 'verify_sources', side_effect=ValueError('corrupt source archive')):
            with self.assertRaisesRegex(ValueError, 'corrupt source'):
                final.inventory(self.root, self.directory, VERSION)

    def test_container_and_theme_mismatch_refuse(self):
        changed = copy.deepcopy(self.cache)
        changed['buildContainerInputs']['reviewImageID'] = 'sha256:' + '0' * 64
        self.write('pd-csd-cache-receipt.json', changed)
        with self.assertRaisesRegex(ValueError, 'container/cache'):
            final.inventory(self.root, self.directory, VERSION)
        self.write('pd-csd-cache-receipt.json', self.cache)
        self.write('theme-receipt.json', dict(themeBinarySHA256='0' * 64))
        with self.assertRaisesRegex(ValueError, 'theme receipt'):
            final.inventory(self.root, self.directory, VERSION)

    def extraction_fixture(self, command, cwd, **kwargs):
        tree = cwd / 'squashfs-root'
        (tree / 'usr/runtime/lib').mkdir(parents=True)
        (tree / 'AppRun').write_bytes(b'\x7fELFfinal AppRun')
        (tree / 'usr/app').mkdir()
        (tree / 'usr/app/test').write_bytes(b'\x7fELFfinal application')
        theme = tree / 'usr/runtime/System/Library/Themes/Adwaita.theme/Adwaita'
        theme.parent.mkdir(parents=True)
        theme.write_bytes(b'\x7fELFfinal theme')
        return subprocess.CompletedProcess(command, 0)

    def extraction_provenance(self):
        # Hashes refer to final payload fixture, not a dist/stage tree.
        import hashlib
        self.provenance.update(applicationPayload={'app/test': dict(sha256=hashlib.sha256(b'\x7fELFfinal application').hexdigest())},
            payloadIdentityChecks={'adwaita': dict(payload=dict(sha256=hashlib.sha256(b'\x7fELFfinal theme').hexdigest()))})
        (self.packages / (BASE + '.provenance.json')).write_text(json.dumps(self.provenance))

    def test_final_extraction_includes_apprun_and_verifies_provenance(self):
        self.extraction_provenance()
        with patch.object(p.subprocess, 'run', side_effect=self.extraction_fixture), \
             patch.object(p, 'payload_closure', return_value=dict(elfCount=3)) as closure:
            result = final.extract(ROOT, self.packages, VERSION, self.root / 'extract')
        self.assertEqual(closure.call_args.args[1], self.root / 'extract/squashfs-root')
        self.assertEqual(result['appImage'], final.file_record(self.packages / (BASE + '.AppImage')))
        self.assertIn('app/test', result['selectedPayloadSHA256'])

    def test_library_added_only_by_packager_refuses_final_closure(self):
        self.extraction_provenance()
        def run(command, **kwargs):
            if command[-1] == '--appimage-extract':
                result = self.extraction_fixture(command, **kwargs)
                (kwargs['cwd'] / 'squashfs-root/packager-extra.so').write_bytes(b'\x7fELFextra')
                return result
            bad = command[-1].endswith('packager-extra.so')
            text = 'libsurprise.so.1 => /usr/lib/libsurprise.so.1 (0x0)\n' if bad else 'libc.so.6 => /usr/lib/libc.so.6 (0x0)\n'
            return subprocess.CompletedProcess(command, 0, text, '')
        with patch.object(p.subprocess, 'run', side_effect=run), \
             patch.object(p.subprocess, 'check_output', return_value=' (NEEDED) [libc.so.6]\n'):
            with self.assertRaisesRegex(ValueError, 'unreviewed host dependency'):
                final.extract(ROOT, self.packages, VERSION, self.root / 'extract')

    def test_changed_payload_refuses_provenance(self):
        self.extraction_provenance()
        def run(command, **kwargs):
            result = self.extraction_fixture(command, **kwargs)
            (kwargs['cwd'] / 'squashfs-root/usr/app/test').write_bytes(b'changed after packaging')
            return result
        with patch.object(p.subprocess, 'run', side_effect=run):
            with self.assertRaisesRegex(ValueError, 'payload differs from provenance'):
                final.extract(ROOT, self.packages, VERSION, self.root / 'extract')

    def test_archived_source_metadata_must_match_final_inputs(self):
        import hashlib
        archive = self.root / 'metadata.tar.gz'
        with tarfile.open(archive, 'w:gz') as target:
            data = b'exact SDK metadata'
            info = tarfile.TarInfo('bundle/metadata/gnustep-toolchain-provenance.json')
            info.size = len(data)
            target.addfile(info, io.BytesIO(data))
        expected = {'metadata/gnustep-toolchain-provenance.json': hashlib.sha256(data).hexdigest()}
        final.source_metadata(archive, expected)
        expected['metadata/gnustep-toolchain-provenance.json'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'source metadata differs'):
            final.source_metadata(archive, expected)
        with self.assertRaisesRegex(ValueError, 'source metadata differs'):
            final.source_metadata(archive, {'metadata/theme-receipt.json': '0' * 64})

    def test_packager_metadata_ties_final_feed_bytes(self):
        self.metadata['artifacts']['updateFeed']['sha256'] = '0' * 64
        self.write(BASE + '.metadata.json', self.metadata)
        with self.assertRaisesRegex(ValueError, 'packager metadata bytes'):
            final.inventory(self.root, self.directory, VERSION)

    def test_workflow_gates_final_payload_and_readback_before_upload(self):
        shell = (ROOT / '.github/scripts/csd-review-container.sh').read_text()
        self.assertNotIn('--prefix dist/stage', shell)
        self.assertNotIn('cp dist/packages/*', shell)
        self.assertLess(shell.index('"$pd_final" extract'), shell.index('"$pd_final" assemble'))
        self.assertLess(shell.index('"$pd_final" assemble'), shell.index('"$pd_final" verify'))
        workflow = (ROOT / '.github/workflows/csd-review.yml').read_text()
        self.assertIn('Tests/out', workflow)
        self.assertIn('Tests/csd-final-review-checks.py', workflow)


if __name__ == '__main__':
    unittest.main()
