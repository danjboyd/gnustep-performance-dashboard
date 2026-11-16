#!/usr/bin/env python3
"""Synthetic producer/adapter/refusal checks and disposable-key signed assembly."""
import base64
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import yaml

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


gate = module('signing_gate', '.github/scripts/custom-signing-input.py')
adapter = module('adapter', '.github/scripts/custom-signing-adapter.py')
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
COMMIT = 'a' * 40
VERSION = '0.1.7'
BASE = 'PerformanceDashboard-' + VERSION + '-x86_64'


class InputChecks(unittest.TestCase):
    def setUp(self):
        self.run = dict(id=12, head_sha=COMMIT, status='completed', conclusion='success', event='push',
            path='.github/workflows/release.yml', repository={'full_name': gate.REPOSITORY},
            head_repository={'full_name': gate.REPOSITORY})
        self.artifacts = dict(total_count=1, artifacts=[dict(name='custom-csd-unsigned-production', id=34,
            expired=False, digest='sha256:' + 'b' * 64)])
        self.environment = dict(name='signing', protection_rules=[dict(type='required_reviewers', reviewers=[{'id': 1}])])

    def validate(self):
        return gate.validate(self.run, self.artifacts, self.environment, COMMIT, '12', 'signing')

    def test_exact_producer_and_protected_environment(self):
        result = self.validate()
        self.assertEqual(result['commit'], COMMIT)
        self.assertEqual(result['artifactID'], '34')
        self.assertEqual(result['environment'], 'signing')

    def test_wrong_commit_run_workflow_or_foreign_repo_refuses(self):
        for field, value in [('head_sha', 'c' * 40), ('id', 13), ('status', 'in_progress'),
                             ('conclusion', 'failure'), ('path', '.github/workflows/ci.yml'),
                             ('event', 'pull_request'), ('head_repository', {'full_name': 'foreign/repo'})]:
            with self.subTest(field=field):
                original = copy.deepcopy(self.run)
                self.run[field] = value
                with self.assertRaises(ValueError): self.validate()
                self.run = original

    def test_review_expired_duplicate_or_undigested_artifact_refuses(self):
        for field, value in [('name', 'custom-csd-unsigned-review'), ('expired', True), ('digest', None)]:
            with self.subTest(field=field):
                original = copy.deepcopy(self.artifacts)
                self.artifacts['artifacts'][0][field] = value
                with self.assertRaises((ValueError, TypeError)): self.validate()
                self.artifacts = original
        self.artifacts['artifacts'] *= 2
        self.artifacts['total_count'] = 2
        with self.assertRaises(ValueError): self.validate()

    def test_missing_protection_and_incomplete_artifact_page_refuse(self):
        self.environment['protection_rules'] = []
        with self.assertRaisesRegex(ValueError, 'reviewer-protected'): self.validate()
        self.setUp()
        self.artifacts['total_count'] = 101
        with self.assertRaisesRegex(ValueError, 'complete artifact'): self.validate()

    def test_digest_and_safe_flat_zip_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); archive = root / 'artifact.zip'
            with zipfile.ZipFile(archive, 'w') as stream: stream.writestr('candidate.AppImage', b'synthetic')
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                gate.unpack(archive, '0' * 64, root / 'wrong')
            self.assertFalse((root / 'wrong').exists())
            gate.unpack(archive, sha(archive), root / 'good')
            self.assertEqual((root / 'good/candidate.AppImage').read_bytes(), b'synthetic')
            self.assertTrue((root / 'good/candidate.AppImage').stat().st_mode & 0o100)
            for name, mode in [('../escape', stat.S_IFREG), ('link', stat.S_IFLNK), ('nested/file', stat.S_IFREG)]:
                with self.subTest(name=name):
                    with zipfile.ZipFile(archive, 'w') as stream:
                        entry = zipfile.ZipInfo(name); entry.external_attr = (mode | 0o644) << 16
                        stream.writestr(entry, b'target')
                    with self.assertRaisesRegex(ValueError, 'unsafe artifact'):
                        gate.unpack(archive, sha(archive), root / 'refused')

    def test_workflow_manual_only_secret_scope_and_required_assembly(self):
        workflow = yaml.load((ROOT / '.github/workflows/sign-custom-candidate.yml').read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow['on']), {'workflow_dispatch'})
        self.assertEqual(workflow['permissions'], {'contents': 'read', 'actions': 'read'})
        jobs = workflow['jobs']; signing = jobs['sign']
        self.assertEqual(signing['needs'], 'preflight')
        self.assertEqual(signing['environment'], '${{ needs.preflight.outputs.environment }}')
        secret_steps = [step for step in signing['steps'] if 'UPDATE_ED_PRIVATE_KEY' in step.get('env', {})]
        self.assertEqual(len(secret_steps), 1)
        self.assertIn('set +x', secret_steps[0]['run'])
        self.assertIn('--verify', secret_steps[0]['run'])
        self.assertNotIn('UPDATE_ED_PRIVATE_KEY', json.dumps(jobs['preflight']))
        self.assertIn('[[ "$GITHUB_SHA" == "$COMMIT" ]]', jobs['preflight']['steps'][0]['run'])
        commands = '\n'.join(step.get('run', '') for step in signing['steps'])
        self.assertIn('--require-signatures', commands)
        source = (ROOT / '.github/scripts/custom-signing-adapter.py').read_text()
        self.assertIn("['unsquashfs'", source)
        self.assertNotIn('--appimage-extract', source)
        self.assertNotIn('gh release', commands)
        self.assertNotIn('git push', commands)
        for job in jobs.values():
            for step in job['steps']:
                self.assertNotIn('${{ inputs.', step.get('run', ''))
                if 'run' in step:
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True, capture_output=True)
        producer = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertNotIn('sign-custom-candidate.yml', producer)
        self.assertNotIn('secrets.', json.dumps(yaml.load(producer, Loader=yaml.BaseLoader)))


class AdapterChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name); self.inputs = self.root / 'inputs'; self.inputs.mkdir()
        self.output = self.root / 'output'; self.evidence = self.root / 'evidence'; self.extracted = self.root / 'extracted'
        self.public = base64.b64encode(b'X' * 32).decode()  # public synthetic fixture, never a product anchor
        self.request = dict(commit=COMMIT, producerRunID='12', artifactID='34', artifactSHA256='b' * 64, environment='signing')
        helper = self.root / '.github/scripts/release-selection.py'; helper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / '.github/scripts/release-selection.py', helper)
        packaging = self.root / 'packaging'; (packaging / 'linux').mkdir(parents=True)
        self.write(packaging / 'package.manifest.json', dict(package={'version': VERSION}, updates={'publicEDKey': self.public}))
        self.write(packaging / 'linux/release-production.json', dict(schemaVersion=1, linuxProducer='custom-csd'))
        (self.inputs / (BASE + '.AppImage')).write_bytes(b'synthetic image, never executed')
        (self.inputs / (BASE + '.AppImage.zsync')).write_bytes(b'synthetic delta')
        self.payload = {'app/PerformanceDashboard.app/PerformanceDashboard': b'GUI fixture',
                        'runtime/System/Library/Themes/Adwaita.theme/Adwaita': b'theme fixture'}
        self.provenance = dict(kind='performance-dashboard-custom-csd-review-provenance', officialToolchain=False,
            sourceDirty=False, commit=COMMIT, version=VERSION,
            applicationPayload={'app/PerformanceDashboard.app/PerformanceDashboard': {'sha256': hashlib.sha256(b'GUI fixture').hexdigest()}},
            payloadIdentityChecks={'adwaita': {'payload': {'sha256': hashlib.sha256(b'theme fixture').hexdigest()}}})
        self.write(self.inputs / (BASE + '.provenance.json'), self.provenance)
        self.config = dict(package=dict(id=adapter.PACKAGE, version=VERSION, backend='appimage', platform='linux-x64'),
                           updates={'publicEDKey': self.public})
        asset = lambda name: dict(name=name, sha256=sha(self.inputs / name), sizeBytes=(self.inputs / name).stat().st_size,
            url='https://github.com/danjboyd/gnustep-performance-dashboard/releases/download/v0.1.7/' + name)
        binary = asset(BASE + '.AppImage'); binary.update(backend='appimage', platform='linux-x64', zsync=asset(BASE + '.AppImage.zsync'))
        feed = dict(formatVersion=1, provider='github-release-feed', channel='stable',
            feedUrl='https://danjboyd.github.io/gnustep-performance-dashboard/updates/linux/stable.json',
            package=dict(id=adapter.PACKAGE, version=VERSION), releases=[dict(version=VERSION, tag='v'+VERSION, assets=[binary])])
        self.write(self.inputs / (BASE + '.update-feed.json'), feed)
        nested = io.BytesIO()
        with tarfile.open(fileobj=nested, mode='w', format=tarfile.PAX_FORMAT, pax_headers={'comment': COMMIT}) as stream:
            entry = tarfile.TarInfo('PerformanceDashboard/fixture'); entry.size = 1; stream.addfile(entry, io.BytesIO(b'x'))
        with tarfile.open(self.inputs / ('PerformanceDashboard-'+VERSION+'-sources.tar.gz'), 'w:gz') as stream:
            entry = tarfile.TarInfo('sources/PerformanceDashboard.tar'); entry.size = len(nested.getvalue())
            stream.addfile(entry, io.BytesIO(nested.getvalue()))
        self.receipt = dict(applicationCommit=COMMIT, version=VERSION,
            files={file.name: adapter.final.file_record(file) for file in self.inputs.iterdir()})
        self.write(self.inputs / adapter.final.RECEIPT, self.receipt)

    def write(self, path, value): path.write_text(json.dumps(value))

    def extract(self, command, cwd, **kwargs):
        for relative, data in self.payload.items():
            file = cwd / 'squashfs-root/usr' / relative; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(data)
        config = cwd / 'squashfs-root/usr/metadata/updates/gnustep-packager-update.json'; config.parent.mkdir(parents=True)
        self.write(config, self.config)

    def prepare(self):
        # The independent unsigned-receipt verifier has its own full synthetic
        # gate suite; here isolate the adapter and exercise actual payload ties.
        with patch.object(adapter.final, 'verify_receipt', return_value=sha(self.inputs / adapter.final.RECEIPT)), \
             patch.object(adapter, 'extract_payload', side_effect=self.extract):
            return adapter.prepare(self.root, self.inputs, self.output, self.evidence, self.extracted,
                                   self.request, self.public, VERSION)

    def test_appimage_payload_is_located_without_executing_it(self):
        app = self.root / 'offset-fixture.AppImage'
        prefix = bytearray(128); prefix[:6] = b'\x7fELF\x02\x01'; prefix[8:11] = b'AI\x02'
        block = bytearray(112); block[:4] = b'hsqs'
        struct.pack_into('<I', block, 12, 131072)
        struct.pack_into('<HH', block, 28, 4, 0)
        struct.pack_into('<Q', block, 40, 112)
        app.write_bytes(prefix + block)
        self.assertEqual(adapter.squashfs_offset(app), 128)
        app.write_bytes(prefix + block + block)
        with self.assertRaisesRegex(ValueError, 'one bounded'): adapter.squashfs_offset(app)
        app.write_bytes(b'not an image')
        with self.assertRaisesRegex(ValueError, 'AppImage required'): adapter.squashfs_offset(app)

    def test_public_anchor_adapter_preserves_original_and_binds_hashes(self):
        original = (self.inputs / (BASE + '.provenance.json')).read_bytes()
        record = self.prepare()
        self.assertEqual((self.evidence / 'original-provenance.json').read_bytes(), original)
        self.assertEqual((self.inputs / (BASE + '.provenance.json')).read_bytes(), original)
        adapted = json.loads((self.output / (BASE + '.provenance.json')).read_text())
        self.assertEqual(adapted['updatesPublicEDKey'], self.public)
        self.assertEqual(adapted['updatesPackageIdentifier'], adapter.PACKAGE)
        self.assertEqual(record['originalProvenanceSHA256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(record['adaptedProvenanceSHA256'], sha(self.output / (BASE + '.provenance.json')))
        self.assertEqual(len(list(self.output.iterdir())), 5)
        with self.assertRaisesRegex(ValueError, 'fresh'): self.prepare()

    def test_wrong_public_anchor_and_package_are_refused(self):
        self.config['updates']['publicEDKey'] = base64.b64encode(b'Y' * 32).decode()
        with self.assertRaisesRegex(ValueError, 'anchor mismatch'): self.prepare()
        self.assertFalse(self.output.exists())
        self.setUp(); self.config['package']['id'] = 'wrong.package'
        with self.assertRaisesRegex(ValueError, 'package identity'): self.prepare()

    def test_changed_asset_mixed_commit_or_payload_are_refused(self):
        self.request['commit'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'receipt mismatch'): self.prepare()
        self.request['commit'] = COMMIT
        (self.inputs / (BASE + '.AppImage')).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'producer bytes changed'): self.prepare()
        self.setUp(); self.payload['app/PerformanceDashboard.app/PerformanceDashboard'] = b'changed GUI'
        with self.assertRaisesRegex(ValueError, 'payload differs'): self.prepare()

    def test_disposable_key_sign_verify_and_required_assembly(self):
        key = self.root / 'throwaway.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(key)], check=True, capture_output=True)
        key.chmod(0o600)
        seed = subprocess.check_output(['openssl', 'pkey', '-in', str(key), '-outform', 'DER'])[-32:]
        public = subprocess.check_output(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'])[-32:]
        self.public = base64.b64encode(public).decode()
        self.config['updates']['publicEDKey'] = self.public
        self.write(self.root / 'packaging/package.manifest.json', dict(package={'version': VERSION}, updates={'publicEDKey': self.public}))
        self.prepare()
        env = {'PATH': '/usr/bin:/bin', 'UPDATE_ED_PRIVATE_KEY': base64.b64encode(seed).decode(), 'UPDATE_ED_PUBLIC_KEY': self.public}
        feed = self.output / (BASE + '.update-feed.json')
        def command(*args, ok=True):
            result = subprocess.run([sys.executable, *map(str, args)], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode == 0, ok, result.stderr)
        assembly = self.root / 'release'
        args = [ROOT / 'scripts/assemble-release.py', '--input', self.output, '--output', assembly,
                '--version', VERSION, '--commit', COMMIT, '--require-backend', 'appimage', '--require-signatures']
        command(*args, ok=False)  # Missing signatures must fail before any output.
        self.assertFalse(assembly.exists())
        command(ROOT / 'scripts/sign-update-feed.py', feed, self.output)
        command(ROOT / 'scripts/sign-update-feed.py', '--verify', feed, self.output)
        command(*args)
        self.assertEqual(len([p for p in assembly.iterdir() if p.is_file()]), 7)
        signed = json.loads(feed.read_text()); signed['releases'][0]['assets'][0]['edSignature'] = base64.b64encode(b'0'*64).decode()
        self.write(feed, signed)
        command(ROOT / 'scripts/sign-update-feed.py', '--verify', feed, self.output, ok=False)


if __name__ == '__main__':
    unittest.main()
