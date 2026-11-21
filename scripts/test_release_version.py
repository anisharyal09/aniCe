# SPDX-License-Identifier: GPL-3.0-or-later
"""Check version ordering and rejection of ambiguous release tags."""
from pathlib import Path
import re
import unittest

from release_version import parse_tag

ROOT = Path(__file__).resolve().parents[1]


class ReleaseVersionTest(unittest.TestCase):
    def test_release_sequence(self):
        tags = ["v0.4.0-alpha.1", "v0.4.0-alpha.19", "v0.4.0-beta.1", "v0.4.0-beta.19", "v0.4.0-rc.1", "v0.4.0-rc.19", "v0.4.0", "v0.4.1-alpha.1"]
        codes = [parse_tag(tag)[1] for tag in tags]
        self.assertEqual(codes, sorted(set(codes)))
        self.assertEqual(parse_tag("v0.4.0-beta.1"), ("0.4.0-beta.1", 40021, True))
        self.assertEqual(parse_tag("v0.4.0"), ("0.4.0", 40099, False))

    def test_beta_four_keeps_monotonic_update_ordering(self):
        self.assertEqual(parse_tag("v0.9.0-beta.4"), ("0.9.0-beta.4", 90024, True))
        tags = ["v0.9.0-beta.3", "v0.9.0-beta.4", "v0.9.0-rc.1", "v0.9.0"]
        codes = [parse_tag(tag)[1] for tag in tags]
        self.assertEqual(codes, sorted(set(codes)))

    def test_native_development_versions_agree_with_release_tag_ordering(self):
        android = (ROOT / "apps/android/app/build.gradle.kts").read_text(encoding="utf-8")
        macos = (ROOT / "apps/macos/aniCe.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        version_match = re.search(r'versionName\s*=.*\?:\s*"([^"]+)"', android)
        code_match = re.search(r'versionCode\s*=.*\?:\s*(\d+)', android)
        self.assertIsNotNone(version_match)
        self.assertIsNotNone(code_match)
        version, code, _ = parse_tag("v" + version_match.group(1))
        self.assertEqual(int(code_match.group(1)), code)
        self.assertEqual(re.findall(r'MARKETING_VERSION\s*=\s*"([^"]+)"', macos), [version, version])
        self.assertEqual(re.findall(r'CURRENT_PROJECT_VERSION\s*=\s*(\d+)', macos), [str(code), str(code)])

    def test_invalid_tags(self):
        for tag in ["0.4.0", "v01.0.0", "v0.100.0", "v0.0.100", "v2001.0.0", "v0.0.1-beta.0", "v0.0.1-alpha.20", "v0.0.1-rc", "v0.0.1+build", "v0.0.1\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)

    def test_maximum(self):
        self.assertLessEqual(parse_tag("v2000.99.99")[1], 2_147_483_647)


if __name__ == "__main__":
    unittest.main()
