#!/usr/bin/env python3
"""Offline producer selection and automatic-workflow signing boundary checks."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import yaml

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_selection', ROOT / '.github/scripts/release-selection.py')
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)


class ProducerChecks(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.production = Path(tmp.name) / 'production.json'
        self.production.write_text(json.dumps({'schemaVersion': 1, 'linuxProducer': 'custom-csd'}))
        # Selection scenarios use a fixed release fixture, independent of the
        # development branch's current product version.
        self.manifest = Path(tmp.name) / 'manifest.json'
        manifest = json.loads((ROOT / 'packaging/package.manifest.json').read_text())
        manifest['package']['version'] = '0.1.7'
        self.manifest.write_text(json.dumps(manifest))

    def test_custom_branch_tag_and_explicit_review_version(self):
        for ref, override, expected in [('refs/heads/release/v0.1.7', '', '0.1.7'),
                ('refs/tags/v0.1.7', '', '0.1.7'),
                ('refs/heads/release/v0.1.7', '0.1.7-review', '0.1.7-review')]:
            with self.subTest(ref=ref, override=override):
                self.assertEqual(selection.select(self.manifest, self.production, ref, override),
                                 {'version': expected, 'producer': 'custom-csd'})

    def test_invalid_or_missing_selection_and_wrong_version_refused(self):
        for producer in ('auto', 'custom', None):
            self.production.write_text(json.dumps({'schemaVersion': 1, 'linuxProducer': producer}))
            with self.assertRaisesRegex(ValueError, 'producer required'):
                selection.select(self.manifest, self.production, 'refs/heads/release/v0.1.7')
        self.production.unlink()
        with self.assertRaises(OSError):
            selection.select(self.manifest, self.production, 'refs/heads/release/v0.1.7')
        self.production.write_text(json.dumps({'schemaVersion': 1, 'linuxProducer': 'custom-csd'}))
        for ref, override in [('refs/tags/v0.1.6', ''), ('refs/heads/release/v0.1.7', '0.1.8'),
                              ('refs/heads/release/v0.1.7', '0.1.7\ninjected=1')]:
            with self.assertRaisesRegex(ValueError, 'package.version'):
                selection.select(self.manifest, self.production, ref, override)

    def test_managed_is_explicit(self):
        self.production.write_text(json.dumps({'schemaVersion': 1, 'linuxProducer': 'managed'}))
        self.assertEqual(selection.select(self.manifest, self.production, 'refs/tags/v0.1.7')['producer'], 'managed')

    def test_numeric_unsigned_path_requires_custom_and_exact_base(self):
        self.assertEqual(selection.custom_version(self.manifest, self.production, 'production', '0.1.7')['version'], '0.1.7')
        self.assertEqual(selection.custom_version(self.manifest, self.production, 'review', '0.1.7-review.1')['version'], '0.1.7-review.1')
        for mode, version in [('production', '0.1.7-review'), ('production', '0.1.6'),
                              ('review', '0.1.7'), ('unknown', '0.1.7')]:
            with self.subTest(mode=mode, version=version), self.assertRaises(ValueError):
                selection.custom_version(self.manifest, self.production, mode, version)
        self.production.write_text(json.dumps({'schemaVersion': 1, 'linuxProducer': 'managed'}))
        with self.assertRaisesRegex(ValueError, 'Custom producer'):
            selection.custom_version(self.manifest, self.production, 'production', '0.1.7')

    def test_automatic_workflow_has_no_real_signing_surface(self):
        text = (ROOT / '.github/workflows/release.yml').read_text()
        workflow = yaml.safe_load(text)
        triggers = workflow.get('on', workflow.get(True))
        self.assertEqual(triggers['push']['branches'], ['release/**'])
        self.assertEqual(triggers['push']['tags'], ['v*'])
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        for forbidden in ('secrets.', 'secrets: inherit', 'UPDATE_ED_PRIVATE_KEY',
                          'sign-update-feed.py', '--require-signatures', 'contents: write'):
            self.assertNotIn(forbidden, json.dumps(workflow))
        jobs = workflow['jobs']
        self.assertEqual(jobs['linux-managed']['if'], "needs.version.outputs.producer == 'managed'")
        self.assertEqual(jobs['linux-custom']['if'], "needs.version.outputs.producer == 'custom-csd'")
        self.assertEqual(jobs['linux-custom']['uses'], './.github/workflows/csd-review.yml')
        self.assertEqual(jobs['linux-custom']['with']['mode'], 'production')
        self.assertNotIn('secrets', jobs['linux-custom'])
        self.assertNotIn('release', jobs)
        ci_text = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('/usr/bin/python3 Tests/release-producer-checks.py', ci_text)
        self.assertIn('python3-yaml', ci_text)
        self.assertIn('python3 Tests/release-assembly-checks.py', ci_text)
        self.assertIn('python3 Tests/update-signing-checks.py', ci_text)
        self.assertIn('GITHUB_STEP_SUMMARY', text)
        config = json.loads((ROOT / 'packaging/linux/release-production.json').read_text())
        self.assertEqual(config['linuxProducer'], 'custom-csd')


if __name__ == '__main__':
    unittest.main()
