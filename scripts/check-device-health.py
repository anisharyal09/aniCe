#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Preflight device health and guardrail validation for the physical device lab.

Enforces thermal and battery constraints before running heavy interchange tests
to protect hardware and prevent battery-saver throttling from skewing latency results.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = ROOT / "tools/device-lab/inventory.json"


def load_inventory(path=INVENTORY_PATH):
    if not path.is_file():
        return {"guardrails": {"min_battery_percent": 20, "max_temperature_celsius": 42.0}, "devices": []}
    return json.loads(path.read_text(encoding="utf-8"))


def find_adb():
    candidate = shutil.which("adb")
    if candidate:
        return candidate
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        val = os.environ.get(var)
        if val:
            path = Path(val) / "platform-tools/adb"
            if path.is_file():
                return str(path)
    for candidate_dir in (
        Path.home() / "Library/Android/sdk",
        Path.home() / "Android/Sdk",
        Path("/usr/local/lib/android/sdk"),
    ):
        path = candidate_dir / "platform-tools/adb"
        if path.is_file():
            return str(path)
    raise RuntimeError("adb not found on PATH or in ANDROID_HOME")


def parse_battery_info(dumpsys_output):
    level_match = re.search(r"\blevel:\s*(\d+)", dumpsys_output)
    temp_match = re.search(r"\btemperature:\s*(\d+)", dumpsys_output)
    scale_match = re.search(r"\bscale:\s*(\d+)", dumpsys_output)

    if not level_match or not temp_match:
        raise ValueError("Could not parse battery level or temperature from dumpsys battery")

    level = int(level_match.group(1))
    scale = int(scale_match.group(1)) if scale_match else 100
    battery_pct = round((level / scale) * 100, 1)

    # Android reports temperature in tenths of a degree Celsius (e.g., 272 = 27.2°C)
    raw_temp = int(temp_match.group(1))
    temp_celsius = raw_temp / 10.0 if raw_temp > 100 else float(raw_temp)

    return {
        "level_percent": battery_pct,
        "temperature_celsius": temp_celsius,
    }


def check_health(serial=None, adb_path=None, output_path=None):
    inventory = load_inventory()
    guardrails = inventory.get("guardrails", {})
    min_battery = guardrails.get("min_battery_percent", 20)
    max_temp = guardrails.get("max_temperature_celsius", 42.0)

    adb = adb_path or find_adb()

    cmd = [adb]
    if serial:
        cmd += ["-s", serial]
    cmd += ["shell", "dumpsys", "battery"]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise RuntimeError("Failed to query dumpsys battery: " + result.stderr.strip())

    metrics = parse_battery_info(result.stdout)
    battery = metrics["level_percent"]
    temp = metrics["temperature_celsius"]

    report = {
        "serial": serial or "default",
        "battery_percent": battery,
        "temperature_celsius": temp,
        "min_battery_threshold": min_battery,
        "max_temperature_threshold": max_temp,
        "healthy": True,
        "violations": [],
    }

    if battery < min_battery:
        report["healthy"] = False
        report["violations"].append(
            f"Battery level {battery}% is below minimum threshold of {min_battery}%"
        )

    if temp > max_temp:
        report["healthy"] = False
        report["violations"].append(
            f"Battery temperature {temp}°C exceeds safety ceiling of {max_temp}°C"
        )

    if output_path:
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2), encoding="utf-8")

    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="Target device adb serial")
    parser.add_argument("--adb", help="Explicit path to adb binary")
    parser.add_argument("--output", type=Path, help="Path to write device-health.json report")
    args = parser.parse_args(argv)

    try:
        report = check_health(args.serial, args.adb, args.output)
    except Exception as error:
        print(f"ERROR: Device health check failed: {error}", file=sys.stderr)
        return 1

    print(f"Device [{report['serial']}] Health: "
          f"Battery: {report['battery_percent']}% (min {report['min_battery_threshold']}%), "
          f"Temp: {report['temperature_celsius']}°C (max {report['max_temperature_threshold']}°C)")

    if not report["healthy"]:
        for violation in report["violations"]:
            print(f"VIOLATION: {violation}", file=sys.stderr)
        return 1

    print("DEVICE HEALTH: PASSED (within all guardrail limits)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
