#!/usr/bin/env python3
"""Offline version stamping/mismatch fixtures; no compiler, GUI or packaging."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('app_version', ROOT / 'scripts/app-version.py')
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)

class VersionChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pd-app-version-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'PerformanceDashboard.app'
        self.info = self.bundle / 'Resources/Info-gnustep.plist'
        self.info.parent.mkdir(parents=True)
        self.info.write_text('{\n  ApplicationRelease = "0.1.5";\n  FullVersionID = "0.1.5";\n  NSExecutable = PerformanceDashboard;\n  NSTypes = ({NSName = "Trace";});\n}\n')
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_text(json.dumps({'package': {'version': '0.1.7'}}))

    def test_plain_make_uses_manifest_and_packager_effective_override_wins(self):
        self.assertEqual(version.effective_version(self.manifest, {}), '0.1.7')
        self.assertEqual(version.effective_version(self.manifest, {'GP_PACKAGE_VERSION': '0.1.7-review.2'}), '0.1.7-review.2')

    def test_stamp_preserves_nonversion_metadata_and_updates_all_keys(self):
        version.stamp_bundle(self.bundle, '0.1.7-review')
        self.assertEqual(set(version.read_versions(self.info).values()), {'0.1.7-review'})
        self.assertIn('NSTypes = ({NSName = "Trace";});', self.info.read_text())
        self.assertIn('NSExecutable = PerformanceDashboard;', self.info.read_text())
        self.assertNotIn('0.1.5', self.info.read_text())

    def test_incremental_stamp_changes_version_without_duplicate_keys(self):
        for v in ['0.1.7-review', '0.1.7', '0.1.8-rc1']:
            version.stamp_bundle(self.bundle, v)
            version.check_bundle(self.bundle, v)
        self.assertEqual(self.info.read_text().count('CFBundleShortVersionString ='), 1)

    def test_stale_bundle_fails_real_stage_checker_command(self):
        env = dict(os.environ)
        env.pop('GP_PACKAGE_VERSION', None)
        command = [sys.executable, str(ROOT / 'scripts/app-version.py'), 'check', '--bundle', str(self.bundle), '--manifest', str(self.manifest)]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('differs from effective package version 0.1.7', result.stderr)
        version.stamp_bundle(self.bundle, '0.1.7')
        self.assertEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)

    def test_single_mismatched_key_fails(self):
        version.stamp_bundle(self.bundle, '0.1.7')
        self.info.write_text(self.info.read_text().replace('FullVersionID = "0.1.7"', 'FullVersionID = "0.1.5"'))
        with self.assertRaisesRegex(ValueError, 'differs'):
            version.check_bundle(self.bundle, '0.1.7')

    def test_xml_and_binary_plists_preserve_other_properties(self):
        for fmt in [plistlib.FMT_XML, plistlib.FMT_BINARY]:
            self.info.write_bytes(plistlib.dumps({'NSExecutable': 'PerformanceDashboard', 'ApplicationRelease': 'old', 'Custom': [True, 42]}, fmt=fmt))
            version.stamp_bundle(self.bundle, '0.1.7')
            data = plistlib.loads(self.info.read_bytes())
            self.assertEqual(data['Custom'], [True, 42])
            self.assertEqual(data['CFBundleShortVersionString'], '0.1.7')

    def test_duplicate_keys_refuse_without_mutation(self):
        self.info.write_text('{\n ApplicationRelease = "0.1.5";\n ApplicationRelease = "0.1.6";\n}\n')
        before = self.info.read_bytes()
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            version.stamp_bundle(self.bundle, '0.1.7')
        self.assertEqual(self.info.read_bytes(), before)

    def test_invalid_manifest_or_effective_value_refuses(self):
        for v in ['bad/version', '0.1.7\nunsafe', '"', 7]:
            self.manifest.write_text(json.dumps({'package': {'version': v}}))
            with self.assertRaisesRegex(ValueError, 'supported version'):
                version.effective_version(self.manifest, {})

    def test_about_reads_stamped_bundle_and_no_version_literal_survives(self):
        source = (ROOT / 'Dashboard/PDAppController.m').read_text()
        about = source.split('- (void) showAbout:')[1].split('- (void) installHelper:')[0]
        self.assertIn('[[NSBundle mainBundle] infoDictionary]', about)
        self.assertIn('@"CFBundleShortVersionString"', about)
        self.assertIn('@"Version %@', about)
        self.assertNotRegex(about, r'Version [0-9]+\.[0-9]+\.[0-9]+')
        self.assertNotRegex((ROOT / 'Dashboard/PerformanceDashboardInfo.plist').read_text(), r'(?:ApplicationRelease|FullVersionID)\s*=')

    def test_build_stage_and_final_package_enforce_same_contract(self):
        make = (ROOT / 'Dashboard/GNUmakefile').read_text()
        self.assertIn('python3 ../scripts/app-version.py stamp --bundle PerformanceDashboard.app', make)
        stage = (ROOT / 'scripts/package-stage.sh').read_text()
        self.assertLess(stage.index('app-version.py" check'), stage.index('rm -rf "$stage_root"'))
        package = (ROOT / 'scripts/package-linux.sh').read_text()
        self.assertIn('check --bundle "$root/app/PerformanceDashboard.app" --version "$version"', package)
        self.assertIn('Tests/app-version-checks.py', (ROOT / 'Tests/run.sh').read_text())

if __name__ == '__main__':
    unittest.main()
