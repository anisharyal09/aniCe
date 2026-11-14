#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks dark packaged icon exports and explicit Android system Light selection."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "apps/android/app/src/main/res"
ATTRIBUTE = "{http://schemas.android.com/apk/res/android}"


class BrandIconTests(unittest.TestCase):
    def test_export_uses_dark_artwork_for_every_packaged_mac_icon(self):
        spec = importlib.util.spec_from_file_location("brand_icons", ROOT / "assets/logo/export-brand-icons.py")
        exporter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(exporter)
        catalog = exporter.MAC / "AppIcon.appiconset"
        entries = json.loads((catalog / "Contents.json").read_text())["images"]
        self.assertEqual(len(entries), 10)
        targets = {catalog / entry["filename"] for entry in entries}
        self.assertEqual(len(targets), 10)
        with tempfile.TemporaryDirectory(prefix="anice-icons-") as temp:
            folder = Path(temp)
            with patch.object(exporter, "REVIEW", folder / "review"), \
                 patch.object(exporter, "ANDROID", folder / "android"), \
                 patch.object(exporter, "magick") as render:
                exporter.export()
        writes = [call.args for call in render.call_args_list if call.args[-1] in targets]
        self.assertEqual({args[-1] for args in writes}, targets)
        self.assertEqual(len(writes), 10)
        for args in writes:
            self.assertEqual(args[0].name, "DockIcon-dark.png")
        backgrounds = [call.args for call in render.call_args_list
                       if call.args[-1] == exporter.ANDROID_DARK_BACKGROUND]
        self.assertEqual(len(backgrounds), 1)
        self.assertEqual(backgrounds[0][0].name, "mac-dock-dark-highlighted-background.png")
        self.assertIn("880x880+72+72", backgrounds[0])
        self.assertIn("#171A1C", backgrounds[0])
        self.assertIn("remove", backgrounds[0])

    def test_android_uses_dark_fallback_and_light_only_in_system_day_mode(self):
        default = ET.parse(ANDROID / "drawable/ic_launcher_background.xml").getroot()
        light = ET.parse(ANDROID / "drawable-notnight/ic_launcher_background.xml").getroot()
        self.assertEqual(default.tag, "layer-list")
        self.assertEqual(len(default.findall("item")), 1, "The Dock rim is already baked into the background")
        self.assertEqual(default.find("item").get(ATTRIBUTE + "drawable"), "@drawable/ic_launcher_background_dark")
        self.assertTrue((ANDROID / "drawable-nodpi/ic_launcher_background_dark.png").is_file())
        self.assertEqual(light.tag, "shape")
        self.assertEqual(light.find("solid").get(ATTRIBUTE + "color"), "@color/launcher_background")
        self.assertFalse((ANDROID / "drawable-night/ic_launcher_background.xml").exists(),
                         "System Dark must inherit the dark fallback, not a separate override")
        color = ET.parse(ANDROID / "values/launcher.xml").getroot().find("color")
        self.assertEqual(color.text.upper(), "#F1F0EC")


if __name__ == "__main__":
    unittest.main()
