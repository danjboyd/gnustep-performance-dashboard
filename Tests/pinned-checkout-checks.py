#!/usr/bin/env python3
"""Exercise source-pin refusal using disposable local Git trees; no network."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PinnedCheckoutChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'packaging').mkdir()
        self.script = self.root / 'scripts/pinned-checkout.sh'
        shutil.copy2(ROOT / 'scripts/pinned-checkout.sh', self.script)
        self.source = self.root / 'source'
        self.source.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.source)], check=True)
        (self.source / '.gitignore').write_text('obj/\n')
        (self.source / 'reviewed.m').write_text('reviewed source\n')
        subprocess.run(['git', '-C', str(self.source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.source), '-c', 'user.name=Daniel Boyd',
                        '-c', 'user.email=danieljboyd@icloud.com', 'commit', '-qm', 'fixture'], check=True)
        revision = subprocess.check_output(['git', '-C', str(self.source), 'rev-parse', 'HEAD'], text=True).strip()
        (self.root / 'packaging/release-inputs.json').write_text(json.dumps({
            'gnustep-trellis': dict(url='https://github.com/example/fixture.git', revision=revision)}))

    def verify(self):
        return subprocess.run([str(self.script), '--verify', 'gnustep-trellis', str(self.source)],
                              text=True, capture_output=True)

    def test_reviewed_source_and_ignored_build_outputs_pass(self):
        (self.source / 'obj').mkdir()
        (self.source / 'obj/receipt.json').write_text('{}')
        self.assertEqual(self.verify().returncode, 0)

    def test_untracked_source_refuses(self):
        (self.source / 'unreviewed.h').write_text('unexpected source')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_changed_tracked_source_refuses(self):
        (self.source / 'reviewed.m').write_text('changed source')
        self.assertNotEqual(self.verify().returncode, 0)


if __name__ == '__main__':
    unittest.main()
