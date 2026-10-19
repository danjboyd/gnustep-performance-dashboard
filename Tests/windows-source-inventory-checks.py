#!/usr/bin/env python3
"""Check split-package mapping and rejection of mismatched source metadata."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('inventory',
    Path(__file__).resolve().parents[1] / 'scripts/windows-source-inventory.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / 'clang64.db'
        packages = []
        with tarfile.open(self.path, 'w:gz') as archive:
            for name in ('runtime', 'runtime-tools'):
                data = (f'%NAME%\n{name}\n\n%BASE%\nshared-source\n\n'
                        f'%VERSION%\n1.2-3\n\n%SHA256SUM%\n{name}-digest\n\n'
                        '%LICENSE%\nMIT\n').encode()
                member = tarfile.TarInfo(f'{name}/desc')
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
                packages.append(dict(name=name, version='1.2-3',
                                     sha256=name+'-digest', repo='clang64'))
        self.lock = {'locked_packages': packages, 'sync_databases': [
            dict(repo='clang64', file=self.path.name,
                 sha256=hashlib.sha256(self.path.read_bytes()).hexdigest())]}

    def test_split_packages_share_explicit_source_base(self):
        sources = module.inventory(self.lock, self.root)['sources']
        self.assertEqual(len(sources), 1)
        self.assertEqual(sources[0]['binaryPackages'], ['runtime', 'runtime-tools'])
        self.assertEqual(sources[0]['candidateUrl'],
                         'https://repo.msys2.org/mingw/sources/shared-source-1.2-3.src.tar.zst')

    def test_selected_package_does_not_pull_unstaged_sibling(self):
        result = module.inventory(self.lock, self.root, ['runtime'])
        self.assertEqual(result['sources'][0]['binaryPackages'], ['runtime'])

    def test_unknown_package_rejected(self):
        with self.assertRaisesRegex(ValueError, 'absent'):
            module.inventory(self.lock, self.root, ['missing'])

    def test_database_tampering_rejected(self):
        self.path.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            module.inventory(self.lock, self.root)

    def test_binary_version_or_digest_mismatch_rejected(self):
        for key in ('version', 'sha256'):
            with self.subTest(key=key):
                original = self.lock['locked_packages'][0][key]
                self.lock['locked_packages'][0][key] = 'wrong'
                with self.assertRaisesRegex(ValueError, 'differs from snapshot'):
                    module.inventory(self.lock, self.root)
                self.lock['locked_packages'][0][key] = original


if __name__ == '__main__':
    unittest.main()
