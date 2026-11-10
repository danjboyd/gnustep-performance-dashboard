#!/usr/bin/env python3
"""Static guard against fallback source/tag drift; no SDK build or network."""
import ast
import hashlib
import json
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]

class RobinSourceChecks(unittest.TestCase):
    def test_fallback_matches_recorded_exact_libobjc2_cmake(self):
        pin = json.loads((ROOT / "packaging/linux/robin-map-source.json").read_text())
        evidence = pin["upstreamBuildDescription"]
        self.assertEqual(evidence["libobjc2Revision"], "b67709ad7851973fde127022d8ac6a710c82b1d5")
        self.assertIn(evidence["libobjc2Revision"], evidence["url"])
        tag = re.search(r"GIT_TAG\s+(\S+)\)", evidence["recordedExcerpt"])[1]
        self.assertEqual(tag, pin["tag"])
        self.assertEqual(pin["tag"], "v1.4.0")
        self.assertEqual(pin["revision"], "4ec1bf19c6a96125ea22062f38c2cf5b958e448e")
        self.assertEqual(pin["archiveURL"], "https://codeload.github.com/Tessil/robin-map/tar.gz/" + pin["revision"])
        self.assertRegex(pin["archiveSHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(evidence["sha256"], r"^[0-9a-f]{64}$")

    def test_collector_uses_pin_and_verifies_bytes(self):
        text = (ROOT / "scripts/collect-release-sources.py").read_text()
        ast.parse(text)
        self.assertIn('packaging/linux/robin-map-source.json', text)
        self.assertNotIn('revision="v1.2.1"', text)
        self.assertIn('component.get("archiveSHA256")', text)
        self.assertIn('libobjc2 changed; audit its fallback source', text)
        self.assertIn('Corresponding source archive digest mismatch', text)

if __name__ == "__main__":
    unittest.main()
