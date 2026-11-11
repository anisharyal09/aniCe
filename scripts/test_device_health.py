#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for scripts/check-device-health.py."""

import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import importlib.util
spec = importlib.util.spec_from_file_location(
    "check_device_health",
    Path(__file__).resolve().parent / "check-device-health.py"
)
device_health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(device_health)


class DeviceHealthTests(unittest.TestCase):
    def test_parse_battery_info_standard(self):
        output = """Current Battery Service state:
  AC powered: false
  USB powered: true
  Wireless powered: false
  Max charging current: 500000
  Max charging voltage: 5000000
  Charge counter: 3824000
  status: 2
  health: 2
  present: true
  level: 80
  scale: 100
  voltage: 4123
  temperature: 272
  technology: Li-ion
"""
        metrics = device_health.parse_battery_info(output)
        self.assertEqual(metrics["level_percent"], 80.0)
        self.assertEqual(metrics["temperature_celsius"], 27.2)

    def test_parse_battery_info_custom_scale(self):
        output = "level: 45\nscale: 50\ntemperature: 310\n"
        metrics = device_health.parse_battery_info(output)
        self.assertEqual(metrics["level_percent"], 90.0)
        self.assertEqual(metrics["temperature_celsius"], 31.0)

    def test_parse_battery_info_missing_fields(self):
        with self.assertRaises(ValueError):
            device_health.parse_battery_info("no data")

    def test_load_inventory_fallback(self):
        non_existent = Path("/non/existent/inventory.json")
        inv = device_health.load_inventory(non_existent)
        self.assertEqual(inv["guardrails"]["min_battery_percent"], 20)
        self.assertEqual(inv["guardrails"]["max_temperature_celsius"], 42.0)

    def test_check_health_passes_when_healthy(self):
        dumpsys_sample = "level: 85\nscale: 100\ntemperature: 290\n"
        with patch.object(device_health, "find_adb", return_value="/mock/adb"), \
             patch.object(device_health.subprocess, "run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=dumpsys_sample)
            report = device_health.check_health(serial="TEST_SERIAL")
            self.assertTrue(report["healthy"])
            self.assertEqual(report["violations"], [])
            self.assertEqual(report["battery_percent"], 85.0)
            self.assertEqual(report["temperature_celsius"], 29.0)

    def test_check_health_flags_violations(self):
        # Battery too low (15%), temp too high (45.0°C)
        dumpsys_sample = "level: 15\nscale: 100\ntemperature: 450\n"
        with patch.object(device_health, "find_adb", return_value="/mock/adb"), \
             patch.object(device_health.subprocess, "run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=dumpsys_sample)
            report = device_health.check_health(serial="TEST_SERIAL")
            self.assertFalse(report["healthy"])
            self.assertEqual(len(report["violations"]), 2)
            self.assertIn("Battery level 15.0%", report["violations"][0])
            self.assertIn("Battery temperature 45.0°C", report["violations"][1])

    def test_check_health_writes_output_file(self):
        dumpsys_sample = "level: 70\nscale: 100\ntemperature: 250\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            out_path = Path(tmpdir) / "reports/device-health.json"
            with patch.object(device_health, "find_adb", return_value="/mock/adb"), \
                 patch.object(device_health.subprocess, "run") as mock_run:
                mock_run.return_value = MagicMock(returncode=0, stdout=dumpsys_sample)
                report = device_health.check_health(serial="TEST_SERIAL", output_path=out_path)
                self.assertTrue(out_path.is_file())
                data = json.loads(out_path.read_text(encoding="utf-8"))
                self.assertEqual(data["serial"], "TEST_SERIAL")
                self.assertTrue(data["healthy"])

    def test_main_cli_healthy_exits_0(self):
        with patch.object(device_health, "check_health") as mock_check:
            mock_check.return_value = {
                "serial": "DEV1",
                "battery_percent": 80.0,
                "temperature_celsius": 28.0,
                "min_battery_threshold": 20,
                "max_temperature_threshold": 42.0,
                "healthy": True,
                "violations": [],
            }
            code = device_health.main(["--serial", "DEV1"])
            self.assertEqual(code, 0)

    def test_main_cli_violation_exits_1(self):
        with patch.object(device_health, "check_health") as mock_check:
            mock_check.return_value = {
                "serial": "DEV1",
                "battery_percent": 10.0,
                "temperature_celsius": 50.0,
                "min_battery_threshold": 20,
                "max_temperature_threshold": 42.0,
                "healthy": False,
                "violations": ["Battery too low", "Temp too hot"],
            }
            code = device_health.main(["--serial", "DEV1"])
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
