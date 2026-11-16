#!/usr/bin/env python3
"""Offline CI policy/data-flow tests; never build an image, SDK, theme or app."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('csd_ci_state', ROOT / '.github/scripts/csd-review-state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class CSDCIChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pd-ci-policy-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.builder = self.root / 'builder'
        self.prefix = self.root / 'sdk'
        for relative in ('packaging/linux', 'docs', '.github/containers', 'builder/toolchains/linux-amd64-clang',
                         'sdk/lib', 'sdk/System/Library/Makefiles'):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        self.config = dict(builder=dict(revision='a' * 40), lock='packaging/linux/lock.json', fallbackSource=dict(name='robin-map-fallback', url='https://example.invalid/robin.git', revision='c' * 40))
        self.lock = dict(install_domain='LOCAL', components=[dict(name=name, url='https://example.invalid/' + name,
                          revision='b' * 40, configure_args=[], patches=[]) for name in state.NAMES])
        self.write('packaging/linux/csd-ci-inputs.json', self.config)
        self.write('packaging/linux/lock.json', self.lock)
        (self.builder / 'toolchains/linux-amd64-clang/Dockerfile').write_text('FROM debian:13\n')
        self.write('docs/v017-builder-source-digests.json', dict(fileSHA256={
            'toolchains/linux-amd64-clang/Dockerfile': state.sha(self.builder / 'toolchains/linux-amd64-clang/Dockerfile')}))
        (self.root / '.github/containers/csd-review.Dockerfile').write_text('FROM pd-csd-sdk-base\n')
        self.inventory = self.root / 'packages.txt'
        self.inventory.write_text('clang\t19\nlibc6\t2.41\n')
        self.container = state.fingerprint(self.root, self.builder, self.inventory,
                                            'debian@sha256:' + 'd' * 64, 'sha256:' + '1' * 64, '1001', '1001')
        (self.prefix / 'lib/fake.so').write_bytes(b'\x7fELFsynthetic SDK bytes, not executable')
        (self.prefix / 'System/Library/Makefiles/GNUstep.sh').write_text('# synthetic fixture\n')
        (self.prefix / 'pd-backend-build.log').write_text('clang -shared libgnustep-back-032 synthetic-link-command\n')
        self.provenance = dict(schema_version=1, kind='custom-gnustep-toolchain-provenance', official=False,
            install_domain='LOCAL', prefix=str(self.prefix.resolve()), lock=dict(sha256=state.sha(self.root / self.config['lock'])),
            components=[dict(c, resolved_commit=c['revision'], applied_patches=c['patches']) for c in self.lock['components']],
            elf_files={'lib/fake.so': dict(sha256=state.sha(self.prefix / 'lib/fake.so'))})
        self.write('sdk/gnustep-toolchain-provenance.json', self.provenance)
        self.write('sdk/pd-csd-build-sources.json', dict(gitSources=[dict(self.config['fallbackSource'], resolvedCommit='c' * 40)]))
        receipt = state.validate_sdk(self.root, self.prefix, self.container, False)
        self.write('sdk/pd-csd-cache-receipt.json', receipt)

    def write(self, relative, data):
        (self.root / relative).write_text(json.dumps(data))

    def test_cache_key_binds_lock_builder_and_container_inventory(self):
        original = state.cache_key(self.root, self.container)
        self.lock['components'][0]['revision'] = 'e' * 40
        self.write('packaging/linux/lock.json', self.lock)
        self.assertNotEqual(original, state.cache_key(self.root, self.container))
        changed = copy.deepcopy(self.container)
        changed['cacheIdentity'] = 'f' * 64
        self.assertNotEqual(state.cache_key(self.root, self.container), state.cache_key(self.root, changed))
        self.config['builder']['revision'] = 'f' * 40
        self.write('packaging/linux/csd-ci-inputs.json', self.config)
        changed['builderCommit'] = 'f' * 40
        self.assertIn('f' * 40, state.cache_key(self.root, changed))

    def test_fingerprint_inventory_and_resolved_image_id_both_rekey(self):
        other = state.fingerprint(self.root, self.builder, self.inventory,
                                 'debian@sha256:' + 'd' * 64, 'sha256:' + '2' * 64, '1001', '1001')
        self.assertNotEqual(other['cacheIdentity'], self.container['cacheIdentity'])
        self.inventory.write_text('clang\t20\nlibc6\t2.41\n')
        changed = state.fingerprint(self.root, self.builder, self.inventory,
                                   'debian@sha256:' + 'd' * 64, 'sha256:' + '3' * 64, '1001', '1001')
        self.assertNotEqual(changed['cacheIdentity'], self.container['cacheIdentity'])

    def test_inspected_builder_file_tampering_refused(self):
        (self.builder / 'toolchains/linux-amd64-clang/Dockerfile').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'builder file changed'):
            state.fingerprint(self.root, self.builder, self.inventory, 'debian@sha256:' + 'd' * 64, 'image', '1001', '1001')

    def test_cache_restore_verifies_payload_bytes_and_receipt(self):
        state.validate_sdk(self.root, self.prefix, self.container)
        (self.prefix / 'lib/fake.so').write_bytes(b'corrupt cached payload')
        with self.assertRaisesRegex(ValueError, 'payload hash mismatch'):
            state.validate_sdk(self.root, self.prefix, self.container)

    def test_moved_prefix_and_wrong_source_refused(self):
        self.provenance['prefix'] = '/old/absolute/prefix'
        self.write('sdk/gnustep-toolchain-provenance.json', self.provenance)
        with self.assertRaisesRegex(ValueError, 'prefix moved'):
            state.validate_sdk(self.root, self.prefix, self.container)
        self.provenance['prefix'] = str(self.prefix.resolve())
        self.provenance['components'][0]['resolved_commit'] = '0' * 40
        self.write('sdk/gnustep-toolchain-provenance.json', self.provenance)
        with self.assertRaisesRegex(ValueError, 'source/patch mismatch'):
            state.validate_sdk(self.root, self.prefix, self.container)

    def test_cache_receipt_and_link_log_are_bound(self):
        receipt = state.load(self.prefix / 'pd-csd-cache-receipt.json')
        receipt['cacheKey'] = 'stale'
        self.write('sdk/pd-csd-cache-receipt.json', receipt)
        with self.assertRaisesRegex(ValueError, 'receipt identity mismatch'):
            state.validate_sdk(self.root, self.prefix, self.container)
        (self.prefix / 'pd-backend-build.log').unlink()
        with self.assertRaises(OSError):
            state.validate_sdk(self.root, self.prefix, self.container)

    def test_inventory_cannot_escape_prefix(self):
        (self.root / 'outside').write_bytes(b'x')
        self.provenance['elf_files']['../outside'] = dict(sha256=state.sha(self.root / 'outside'))
        self.write('sdk/gnustep-toolchain-provenance.json', self.provenance)
        with self.assertRaisesRegex(ValueError, 'escapes prefix'):
            state.validate_sdk(self.root, self.prefix, self.container)

    def test_unexpected_backend_dependencies_refuse(self):
        baseline = dict(backendSHA256='1' * 64, expectedNeeded=['libc.so.6'])
        self.write('packaging/linux/v017-backend-needed.json', baseline)
        log = self.prefix / 'pd-backend-build.log'
        backend = self.prefix / 'lib/fake.so'
        with patch.object(state.subprocess, 'check_output', return_value=' (NEEDED) [libc.so.6]\n'):
            self.assertEqual(state.check_closure(self.root, backend, log)['unexpected'], [])
        with patch.object(state.subprocess, 'check_output', return_value=' (NEEDED) [libsurprise.so.1]\n'):
            with self.assertRaisesRegex(ValueError, 'unexpected backend DT_NEEDED'):
                state.check_closure(self.root, backend, log)

    def test_actual_fallback_checkout_must_match_before_cache(self):
        tree = self.prefix.parent / '.sdk-build/sources/libobjc2/build/_deps/robinmap-src'
        tree.mkdir(parents=True)
        (tree / '.git').mkdir()
        with patch.object(state.subprocess, 'check_output', side_effect=['c' * 40, 'https://example.invalid/robin.git', '']):
            self.assertEqual(state.record_build_sources(self.root, self.prefix)['gitSources'][0]['resolvedCommit'], 'c' * 40)
        with patch.object(state.subprocess, 'check_output', side_effect=['0' * 40, 'https://example.invalid/robin.git']):
            with self.assertRaisesRegex(ValueError, 'fallback source identity changed'):
                state.record_build_sources(self.root, self.prefix)

    def test_workflow_is_manual_unsigned_read_only_and_pinned(self):
        workflow = yaml.load((ROOT / '.github/workflows/csd-review.yml').read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow['on']), {'workflow_dispatch', 'workflow_call'})
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        pins = state.load(ROOT / 'packaging/linux/csd-ci-inputs.json')['actions']
        steps = workflow['jobs']['linux-csd-review']['steps']
        for step in steps:
            if 'uses' in step:
                action, revision = step['uses'].split('@')
                self.assertRegex(revision, '^[0-9a-f]{40}$')
                self.assertEqual(revision, pins[action.split('/')[1]])
            for forbidden in ('git push', 'gh release', 'secrets.', 'sign-update-feed.py', '--release'):
                self.assertNotIn(forbidden, step.get('run', ''))
            self.assertNotIn('${{ inputs.version }}', step.get('run', ''))
        restores = [s for s in steps if s.get('id') == 'sdk-cache']
        self.assertEqual(len(restores), 1)
        self.assertNotIn('restore-keys', restores[0]['with'])
        self.assertEqual(restores[0]['with']['key'], '${{ steps.container.outputs.cache_key }}')

    def test_backend_gate_precedes_receipt_and_workflow_cache_save(self):
        consume = (ROOT / '.github/scripts/csd-review-container.sh').read_text()
        sdk = consume.split('  sdk)')[1].split('  review)')[0]
        self.assertLess(sdk.index('closure --root'), sdk.index('--write-receipt'))
        # Gate is outside the fresh-only branch and thus repeats for cache hits.
        self.assertIn('    fi\n    # Repeat on fresh AND restored SDKs', sdk)
        workflow = yaml.load((ROOT / '.github/workflows/csd-review.yml').read_text(), Loader=yaml.BaseLoader)
        steps = workflow['jobs']['linux-csd-review']['steps']
        sdk_step = next(i for i, step in enumerate(steps) if step.get('run', '').endswith('csd-review-host.sh sdk'))
        save_step = next(i for i, step in enumerate(steps) if 'actions/cache/save@' in step.get('uses', ''))
        self.assertLess(sdk_step, save_step)

    def test_review_pins_uninstalled_xctest_paths_for_direct_and_nested_make(self):
        consume = (ROOT / '.github/scripts/csd-review-container.sh').read_text().split('  review)')[1]
        self.assertIn('export XCTEST_INCLUDE_DIR="$pd_tests" XCTEST_LIBRARY_DIR="$pd_tests/XCTest/obj"', consume)
        self.assertIn('GNUSTEP_MAKEFILES=$GNUSTEP_MAKEFILES XCTEST_INCLUDE_DIR=$XCTEST_INCLUDE_DIR XCTEST_LIBRARY_DIR=$XCTEST_LIBRARY_DIR', consume)
        self.assertIn('make -C Tests/Unit check -j2 GNUSTEP_MAKEFILES="$GNUSTEP_MAKEFILES"', consume)
        self.assertLess(consume.index('export MAKEFLAGS='), consume.index('make -C Tests/Unit check'))

    def test_extra_elf_and_changed_symlink_refuse_cache(self):
        (self.prefix / 'lib/untracked.so').write_bytes(b'\x7fELFunlisted')
        with self.assertRaisesRegex(ValueError, 'ELF inventory incomplete'):
            state.validate_sdk(self.root, self.prefix, self.container)
        (self.prefix / 'lib/untracked.so').unlink()
        (self.prefix / 'lib/alias.so').symlink_to('fake.so')
        with self.assertRaisesRegex(ValueError, 'receipt identity mismatch'):
            state.validate_sdk(self.root, self.prefix, self.container)

    def test_missing_required_dependency_and_quiet_link_log_refuse(self):
        self.write('packaging/linux/v017-backend-needed.json', dict(expectedNeeded=['libc.so.6', 'libXfixes.so.3']))
        with patch.object(state.subprocess, 'check_output', return_value=' (NEEDED) [libc.so.6]\n'):
            with self.assertRaisesRegex(ValueError, 'missing required'):
                state.check_closure(self.root, self.prefix / 'lib/fake.so', self.prefix / 'pd-backend-build.log')
        self.write('packaging/linux/v017-backend-needed.json', dict(expectedNeeded=['libc.so.6']))
        (self.prefix / 'pd-backend-build.log').write_text('Linking bundle libgnustep-back-032...')
        with patch.object(state.subprocess, 'check_output', return_value=' (NEEDED) [libc.so.6]\n'):
            with self.assertRaisesRegex(ValueError, 'verbose backend linker'):
                state.check_closure(self.root, self.prefix / 'lib/fake.so', self.prefix / 'pd-backend-build.log')

    def test_payload_closure_refuses_missing_and_unreviewed_host_entries(self):
        dynamic = ' (NEEDED) [libc.so.6]\n'
        for output, failure in [('libc.so.6 => not found\n', 'unresolved'),
                                ('libsurprise.so.1 => /usr/lib/libsurprise.so.1 (0x0)\n', 'unreviewed host')]:
            with patch.object(state.subprocess, 'check_output', return_value=dynamic), \
                 patch.object(state.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaisesRegex(ValueError, failure):
                    state.payload_closure(ROOT, self.prefix)
        with patch.object(state.subprocess, 'check_output', return_value=dynamic), \
             patch.object(state.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'libc.so.6 => /usr/lib/libc.so.6 (0x0)\n', '')):
            self.assertEqual(state.payload_closure(ROOT, self.prefix)['elfCount'], 1)

    def test_release_selector_separates_unsigned_review_from_signing(self):
        workflow = yaml.load((ROOT / '.github/workflows/release.yml').read_text(), Loader=yaml.BaseLoader)
        jobs = workflow['jobs']
        self.assertEqual(jobs['linux-managed']['if'], "needs.version.outputs.producer == 'managed'")
        self.assertEqual(jobs['linux-custom']['if'], "needs.version.outputs.producer == 'custom-csd'")
        self.assertNotIn('release', jobs)
        self.assertNotIn('secrets', json.dumps(workflow))
        docker = (ROOT / '.github/containers/csd-review.Dockerfile').read_text()
        self.assertIn('libxfixes-dev', docker)
        self.assertNotIn('rm -rf /var/lib/apt/lists', docker)
        config = state.load(ROOT / 'packaging/linux/csd-ci-inputs.json')
        self.assertEqual(config['lock'], 'packaging/linux/v017-custom-toolchain.lock.proposed.json')
        self.assertEqual(config['fallbackSource'], state.load(ROOT / 'packaging/linux/robin-map-source.json'))

    def test_shell_syntax_and_consumption_stays_in_debian_container(self):
        for name in ('csd-review-host.sh', 'csd-review-container.sh'):
            subprocess.run(['bash', '-n', str(ROOT / '.github/scripts' / name)], check=True)
        host = (ROOT / '.github/scripts/csd-review-host.sh').read_text()
        self.assertIn('docker run --rm -v', host)
        self.assertIn('\"$pd_image\" bash', host)
        consume = (ROOT / '.github/scripts/csd-review-container.sh').read_text()
        self.assertIn('--jobs 2', consume)
        self.assertIn('pd-backend-build.log', consume)
        self.assertIn('make -C "$pd_theme" -j2', consume)
        self.assertIn('closure --root', consume)
        self.assertIn('package-linux.sh --version', consume)
        self.assertNotIn('fetch-toolchain.py', consume)
        self.assertNotIn('--release', consume)


if __name__ == '__main__':
    unittest.main()
