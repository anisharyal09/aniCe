# SPDX-License-Identifier: GPL-3.0-or-later
"""Check version ordering and rejection of ambiguous release tags."""
import unittest
from release_version import parse_tag


class ReleaseVersionTest(unittest.TestCase):
    def test_release_sequence(self):
        tags = ["v0.4.0-alpha.1", "v0.4.0-alpha.19", "v0.4.0-beta.1", "v0.4.0-beta.19", "v0.4.0-rc.1", "v0.4.0-rc.19", "v0.4.0", "v0.4.1-alpha.1"]
        codes = [parse_tag(tag)[1] for tag in tags]
        self.assertEqual(codes, sorted(set(codes)))
        self.assertEqual(parse_tag("v0.4.0-beta.1"), ("0.4.0-beta.1", 40021, True))
        self.assertEqual(parse_tag("v0.4.0"), ("0.4.0", 40099, False))

    def test_invalid_tags(self):
        for tag in ["0.4.0", "v01.0.0", "v0.100.0", "v0.0.100", "v2001.0.0", "v0.0.1-beta.0", "v0.0.1-alpha.20", "v0.0.1-rc", "v0.0.1+build", "v0.0.1\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)

    def test_maximum(self):
        self.assertLessEqual(parse_tag("v2000.99.99")[1], 2_147_483_647)


if __name__ == "__main__":
    unittest.main()
