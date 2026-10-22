#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests native-build tool lookup, environment precedence and missing-tool failure."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


class NativeBuildTests(unittest.TestCase):
    # Fake tools exercise builder selection and output placement without compiling the Rust crate.
    def test_private_paths_environment_override_and_missing_tool(self):
        with tempfile.TemporaryDirectory(prefix="anice native build ") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(Path(__file__).with_name("build-pairing-native.py"), root / "scripts")
            android = root / "apps/android"
            android.mkdir(parents=True)
            rustup = root / "rustup"
            ndk = root / "ndk"
            for tag in ('darwin-x86_64', 'linux-x86_64'):
                tools = ndk / 'toolchains/llvm/prebuilt' / tag / 'bin'
                tools.mkdir(parents=True)
                for name in ('aarch64-linux-android29-clang', 'armv7a-linux-androideabi29-clang',
                             'x86_64-linux-android29-clang', 'llvm-ar'):
                    executable = tools / name
                    executable.write_text('#!/bin/sh\nexit 0\n')
                    executable.chmod(0o755)
            homes = [root / "local cargo", root / "environment cargo"]
            # Fake Cargo records its inputs and emits an ABI marker that output-copy assertions inspect.
            for home in homes:
                (home / "bin").mkdir(parents=True)
                cargo = home / "bin/cargo"
                # A shell entry point preserves interpreter paths containing spaces or shell metacharacters.
                cargo.write_text(f'''#!/bin/sh
exec {shlex.quote(sys.executable)} - "$@" <<'PYEOF'
import json, os, pathlib, sys
manifest = pathlib.Path(sys.argv[sys.argv.index('--manifest-path') + 1])
triple = sys.argv[sys.argv.index('--target') + 1]
out = manifest.parent / 'target' / triple / 'release'
out.mkdir(parents=True, exist_ok=True)
(out / 'libanice_pairing.so').write_bytes(triple.encode())
row = {{'args': sys.argv[1:], 'cargo': os.environ['CARGO_HOME'],
       'rustup': os.environ['RUSTUP_HOME'],
       'linker': os.environ['CARGO_TARGET_' + triple.replace('-', '_').upper() + '_LINKER']}}
with (manifest.parents[3] / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(row) + '\\n')
PYEOF
''')
                cargo.chmod(0o755)
            properties = android / "local.properties"
            properties.write_text(f"# Private tools\ncargo.home={homes[0]}\nrustup.home={rustup}\nndk.dir={ndk}\n")
            env = {key: value for key, value in os.environ.items() if key not in {
                "CARGO_HOME", "RUSTUP_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT",
                "ANICE_NDK", "ANDROID_NDK_HOME", "CARGO_TARGET_DIR", "RUSTFLAGS"}}
            env["PATH"] = ""  # No PATH fallback may hide a missing explicitly selected tool.
            # Each row supplies host, CPU, environment overrides, expected Cargo home and failure text.
            cases = [
                ('Darwin', 'arm64', {}, homes[0], None),
                ('Linux', 'x86_64', {}, homes[0], None),
                ('Darwin', 'arm64', {"CARGO_HOME": str(homes[1]), "RUSTUP_HOME": str(root / "override rustup")}, homes[1], None),
                ('Linux', 'x86_64', {"CARGO_HOME": str(root / "missing")}, None, 'Rust toolchain not found'),
                ('Windows', 'AMD64', {}, None, 'Unsupported Android NDK host'),
                ('Linux', 'aarch64', {}, None, 'Unsupported Android NDK host'),
                ('Linux', 'x86_64', {'ANICE_NDK': str(root / 'missing ndk')}, None, 'Android NDK tools not found'),
            ]
            self.assertEqual(7, len(cases))
            self.assertEqual(3, sum(expected is not None for _, _, _, expected, _ in cases))
            self.assertEqual(4, sum(expected is None for _, _, _, expected, _ in cases))
            # Patch host detection inside a fresh process while exercising the real script entry point.
            runner = '''import runpy, sys
from unittest.mock import patch
script, host, machine = sys.argv[1:]
sys.argv = [script, 'android']
with patch('platform.system', return_value=host), patch('platform.machine', return_value=machine):
    runpy.run_path(script, run_name='__main__')
'''
            log = root / "calls.jsonl"
            for host, machine, overrides, expected, error in cases:
                log.unlink(missing_ok=True)
                saved_properties = properties.read_bytes()
                # Rejected configurations must preserve both private settings and previous build outputs.
                saved_outputs = {file: file.read_bytes() for file in (android / "app/build/native").glob("*/libanice_pairing.so")}
                run = subprocess.run([sys.executable, '-c', runner, str(root / "scripts/build-pairing-native.py"), host, machine],
                                     env=env | overrides, capture_output=True, text=True, timeout=10)
                self.assertEqual(saved_properties, properties.read_bytes())
                if expected is None:
                    self.assertNotEqual(0, run.returncode)
                    self.assertIn(error, run.stderr)
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
                    self.assertIn('darwin-x86_64' if host == 'Darwin' else 'linux-x86_64', row['linker'])
                for abi, triple in [("arm64-v8a", "aarch64-linux-android"),
                                   ("armeabi-v7a", "armv7-linux-androideabi"), ("x86_64", "x86_64-linux-android")]:
                    self.assertEqual(triple.encode(), (android / "app/build/native" / abi / "libanice_pairing.so").read_bytes())

            # Clean runners supply tool locations through the environment and have no private properties file.
            properties.unlink()
            log.unlink(missing_ok=True)
            try:
                clean_env = env | {'CARGO_HOME': str(homes[0]), 'RUSTUP_HOME': str(rustup), 'ANICE_NDK': str(ndk)}
                run = subprocess.run([sys.executable, '-c', runner, str(root / 'scripts/build-pairing-native.py'), 'Linux', 'x86_64'],
                                     env=clean_env, capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(len(log.read_text().splitlines()), 3)
                self.assertFalse(properties.exists())
            finally:
                properties.write_bytes(saved_properties)

            # A partially installed NDK must fail before Cargo can replace any ABI output.
            compiler = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android29-clang'
            compiler.unlink()
            log.unlink(missing_ok=True)
            run = subprocess.run([sys.executable, '-c', runner, str(root / 'scripts/build-pairing-native.py'), 'Linux', 'x86_64'],
                                 env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn('NDK executable missing', run.stderr)
            self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main()
