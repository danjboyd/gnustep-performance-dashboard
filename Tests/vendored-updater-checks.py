#!/usr/bin/env python3
"""Check the complete pinned upstream source inventory, excluding build output."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT/'third_party/gnustep-packager-updater'


class VendoredChecks(unittest.TestCase):
    def test_complete_upstream_source_copy(self):
        names = set()
        makefiles = 0
        for entry in (VENDOR/'VENDORED.sha256').read_text().splitlines():
            expected, name = entry.split('  ', 1)
            self.assertNotIn(name, names)
            names.add(name)
            content = (VENDOR/'objc'/name).read_bytes()
            if name.endswith('/Makefile'):
                compatibility = b'OBJCFLAGS += -DHAVE_MODE_T\n'
                self.assertEqual(content.count(compatibility), 1)
                content = content.replace(compatibility, b'')
                makefiles += 1
            self.assertEqual(hashlib.sha256(content).hexdigest(), expected, name)
        self.assertEqual(makefiles, 3)
        actual = {str(p.relative_to(VENDOR/'objc')) for p in (VENDOR/'objc').rglob('*')
                  if p.is_file() and (p.suffix in ('.m', '.c', '.h', '.md') or p.name == 'Makefile')}
        self.assertEqual(actual, names)


if __name__ == '__main__':
    unittest.main(verbosity=2)
