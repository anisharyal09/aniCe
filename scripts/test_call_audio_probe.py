#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run isolated call-probe regressions without Bluetooth or microphone access."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("call_probe_build", ROOT / "scripts/build-call-audio-probe.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


@unittest.skipUnless(sys.platform == "darwin", "requires macOS SDK")
class CallProbeRegression(unittest.TestCase):
    def test_probe_regressions(self):
        with tempfile.TemporaryDirectory(prefix="anice-call-probe-tests-") as directory:
            executable = Path(directory) / "ProbeRegression"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                       "-module-cache-path", str(Path(directory) / "cache")]
            for framework in build.FRAMEWORKS:
                command.extend(["-framework", framework])
            command.extend(str(build.PROBE_DIR / source) for source in build.SWIFT_SOURCES if source != "main.swift")
            command.extend([str(build.PROBE_DIR / "Tests/ProbeRegression.swift"), "-o", str(executable)])
            subprocess.run(command, check=True)
            result = subprocess.run([str(executable)], text=True, capture_output=True, check=True)
            self.assertIn("PASS:", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
