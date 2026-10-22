# SPDX-License-Identifier: GPL-3.0-or-later
# Exercises SDK license setup exit propagation and diagnostic capture from the Linux workflow.
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class AndroidLicenseSetupTests(unittest.TestCase):
    def test_license_pipeline_handles_sigpipe_without_hiding_sdk_failures(self):
        workflow = Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml'
        commands = [line.strip() for line in workflow.read_text().splitlines()
                    if '--licenses' in line and not line.lstrip().startswith('#')]
        self.assertEqual(len(commands), 1)
        with tempfile.TemporaryDirectory(prefix='anice SDK setup ') as directory:
            root = Path(directory)
            sdk = root / 'Android SDK'
            manager = sdk / 'cmdline-tools/latest/bin/sdkmanager'
            manager.parent.mkdir(parents=True)
            manager.write_text('''#!/bin/sh
read -r answer
printf 'sdkmanager: %s; answer=%s\n' "$*" "$answer"
exit "$ANICE_TEST_SDK_EXIT"
''')
            manager.chmod(0o755)
            reports = root / 'build/reports/ci'
            reports.mkdir(parents=True)
            # The manager stops reading early, as the real tool does after accepting its answers.
            for exit_code in (0, 7):
                with self.subTest(exit_code=exit_code):
                    env = os.environ | {'ANDROID_HOME': str(sdk), 'ANICE_TEST_SDK_EXIT': str(exit_code)}
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', commands[0]],
                                            cwd=root, env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    log = (reports / 'android-licenses.log').read_text()
                    self.assertIn('--sdk_root=' + str(sdk), log)
                    self.assertIn('answer=y', log)


if __name__ == '__main__':
    unittest.main()
