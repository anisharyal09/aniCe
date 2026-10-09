#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests native-build tool lookup, environment precedence and missing-tool failure."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class NativeBuildTests(unittest.TestCase):
    def test_private_paths_environment_override_and_missing_tool(self):
        with tempfile.TemporaryDirectory(prefix="anice native build ") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(Path(__file__).with_name("build-pairing-native.py"), root / "scripts")
            android = root / "apps/android"
            android.mkdir(parents=True)
            rustup = root / "rustup"
            ndk = root / "ndk"
            (ndk / "toolchains/llvm/prebuilt/darwin-x86_64/bin").mkdir(parents=True)
            homes = [root / "local cargo", root / "environment cargo"]
            for home in homes:
                (home / "bin").mkdir(parents=True)
                cargo = home / "bin/cargo"
                cargo.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
manifest = pathlib.Path(sys.argv[sys.argv.index('--manifest-path') + 1])
triple = sys.argv[sys.argv.index('--target') + 1]
out = manifest.parent / 'target' / triple / 'release'
out.mkdir(parents=True, exist_ok=True)
(out / 'libanice_pairing.so').write_bytes(triple.encode())
row = {'args': sys.argv[1:], 'cargo': os.environ['CARGO_HOME'],
       'rustup': os.environ['RUSTUP_HOME'],
       'linker': os.environ['CARGO_TARGET_' + triple.replace('-', '_').upper() + '_LINKER']}
with (manifest.parents[3] / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(row) + '\\n')
''')
                cargo.chmod(0o755)
            properties = android / "local.properties"
            properties.write_text(f"# Private tools\ncargo.home={homes[0]}\nrustup.home={rustup}\nndk.dir={ndk}\n")
            env = {key: value for key, value in os.environ.items() if key not in {
                "CARGO_HOME", "RUSTUP_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT",
                "ANICE_NDK", "ANDROID_NDK_HOME", "CARGO_TARGET_DIR", "RUSTFLAGS"}}
            env["PATH"] = ""  # No PATH fallback may hide a missing explicitly selected tool.
            cases = [({}, homes[0]), ({"CARGO_HOME": str(homes[1]), "RUSTUP_HOME": str(root / "override rustup")}, homes[1]),
                     ({"CARGO_HOME": str(root / "missing")}, None)]
            self.assertEqual(3, len(cases))
            self.assertEqual(2, sum(expected is not None for _, expected in cases))
            self.assertEqual(1, sum(expected is None for _, expected in cases))
            log = root / "calls.jsonl"
            for overrides, expected in cases:
                log.unlink(missing_ok=True)
                saved_properties = properties.read_bytes()
                saved_outputs = {file: file.read_bytes() for file in (android / "app/build/native").glob("*/libanice_pairing.so")}
                run = subprocess.run([sys.executable, str(root / "scripts/build-pairing-native.py"), "android"],
                                     env=env | overrides, capture_output=True, text=True, timeout=10)
                self.assertEqual(saved_properties, properties.read_bytes())
                if expected is None:
                    self.assertNotEqual(0, run.returncode)
                    self.assertIn("Rust toolchain not found", run.stderr)
                    self.assertFalse(log.exists())
                    self.assertEqual(saved_outputs, {file: file.read_bytes() for file in (android / "app/build/native").glob("*/libanice_pairing.so")})
                    continue
                self.assertEqual(0, run.returncode, run.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(3, len(calls))
                self.assertEqual({str(expected)}, {row["cargo"] for row in calls})
                self.assertEqual({overrides.get("RUSTUP_HOME", str(rustup))}, {row["rustup"] for row in calls})
                for row in calls:
                    self.assertIn("--locked", row["args"])
                    self.assertTrue(row["linker"].startswith(str(ndk)))
                for abi, triple in [("arm64-v8a", "aarch64-linux-android"),
                                   ("armeabi-v7a", "armv7-linux-androideabi"), ("x86_64", "x86_64-linux-android")]:
                    self.assertEqual(triple.encode(), (android / "app/build/native" / abi / "libanice_pairing.so").read_bytes())


if __name__ == "__main__":
    unittest.main()
