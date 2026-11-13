#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the developer launcher without building or touching connected devices."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DevLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='anice dev ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'checkout', '-qb', 'test/dev-branch'], check=True)
        (self.root / 'scripts').mkdir()
        shutil.copy2(Path(__file__).with_name('dev.sh'), self.root / 'scripts/dev.sh')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin',
                        HOME=str(self.root), CALLS=str(self.log),
                         SDK_LOG=str(self.root / 'sdk-paths'),
                         GRADLE_ARGS_LOG=str(self.root / 'gradle-args'),
                        ANDROID_HOME=str(self.root / 'sdk'), ANDROID_SDK_ROOT='',
                        ANICE_DEVELOPMENT_TEAM='')
        self.tool('adb', '''if [ "$1" = devices ]; then
printf 'List of devices attached\\n%s\\n' "$DEVICES"
elif [ "$3" = shell ] && [ "$4" = getprop ] && [ "$5" = ro.hardware ]; then
printf '%s\\n' "${EMULATOR_HARDWARE:-ranchu}"
else
printf '%s\\n' "$*" >> "$CALLS"
exit "${INSTALL_EXIT:-0}"
fi''')
        android = self.root / 'apps/android'
        android.mkdir(parents=True)
        gradle = android / 'gradlew'
        gradle.write_text('#!/bin/bash\necho build >> "$CALLS"\nprintf "%s\\n" "$*" > "$GRADLE_ARGS_LOG"\nprintf "%s\\n" "${ANDROID_HOME-}" >> "$SDK_LOG"\nexit "${BUILD_EXIT:-0}"\n')
        gradle.chmod(0o755)

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_dev(self, *args, **env):
        return subprocess.run(['bash', str(self.root / 'scripts/dev.sh'), *args],
                              env=self.env | env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_single_device_build_install_launch(self):
        result = self.run_dev('android', DEVICES='phone\tdevice\noffline\toffline')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls().splitlines()
        self.assertEqual(calls[0], 'build')
        self.assertTrue(calls[1].startswith('-s phone install -r '))
        self.assertEqual(calls[2], '-s phone shell am start -W -n io.github.anisharyal09.anice/.MainActivity')

    def test_ambiguous_unauthorized_and_missing_selected_fail_before_build(self):
        for devices, args in [('', ()), ('phone\tunauthorized', ()),
                              ('phone\tunauthorized', ('--serial', 'phone')),
                              ('one\tdevice\ntwo\tdevice', ()),
                              ('one\tdevice', ('--serial', 'missing'))]:
            with self.subTest(devices=devices, args=args):
                result = self.run_dev('android', *args, DEVICES=devices)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('dev:', result.stderr)
                self.assertNotIn('unbound variable', result.stderr)
                self.assertEqual(self.calls(), '')

    def test_selected_device_and_sdk_adb_fallback(self):
        sdk_bin = self.root / 'sdk/platform-tools'
        sdk_bin.mkdir(parents=True)
        shutil.move(self.bin / 'adb', sdk_bin / 'adb')
        result = self.run_dev('android', '--serial', 'two', DEVICES='one\tdevice\ntwo\tdevice')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-s two install -r ', self.calls())

    def test_sdk_derived_from_adb_path_is_exported_to_gradle(self):
        sdk_bin = self.root / 'sdk/platform-tools'
        sdk_bin.mkdir(parents=True)
        shutil.move(self.bin / 'adb', sdk_bin / 'adb')
        result = self.run_dev('android', ANDROID_HOME='', ANDROID_SDK_ROOT='',
                              PATH=f'{sdk_bin}:{self.bin}:/usr/bin:/bin',
                              DEVICES='phone\tdevice')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'sdk-paths').read_text().splitlines()[-1],
                         str(self.root / 'sdk'))

    def test_build_failure_never_installs(self):
        result = self.run_dev('android', DEVICES='phone\tdevice', BUILD_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), 'build\n')

    def test_install_failure_never_launches(self):
        result = self.run_dev('android', DEVICES='phone\tdevice', INSTALL_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('install -r ', self.calls())
        self.assertNotIn('shell am start', self.calls())

    def test_mac_signing_and_verification_precede_launch(self):
        self.tool('uname', 'case "$1" in -s) echo Darwin;; -m) echo arm64;; esac')
        self.tool('osascript', 'echo osascript >> "$CALLS"')
        self.tool('pgrep', 'exit "${RUNNING:-1}"')
        self.tool('sleep', ':')
        self.tool('python3', 'echo python3 >> "$CALLS"')
        self.tool('xcodebuild', "printf 'xcodebuild %s\\n' \"$*\" >> \"$CALLS\"")
        self.tool('open', "printf 'open %s\\n' \"$*\" >> \"$CALLS\"")
        self.tool('codesign', '''echo codesign >> "$CALLS"
if [ "$1" = -dv ]; then
 echo "Authority=${SIGNATURE_AUTHORITY:-Apple Development: Test}" >&2
 echo "TeamIdentifier=${SIGNATURE_TEAM:-TESTTEAM}" >&2
fi''')
        self.assertNotEqual(self.run_dev('mac').returncode, 0)
        self.assertEqual(self.calls(), '')
        result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM', SIGNATURE_TEAM='WRONG')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith('open ') for line in self.calls().splitlines()))
        self.log.unlink()
        result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls().splitlines()
        self.assertEqual([line.split()[0] for line in calls],
                         ['osascript', 'python3', 'xcodebuild', 'codesign', 'codesign', 'open'])
        self.assertIn('build/dev-mac/anice dev ', calls[2])
        self.assertIn('-test_2Fdev-branch', calls[2])
        self.assertNotIn('%', calls[2])
        self.assertIn('INFOPLIST_KEY_CFBundleDisplayName=aniCe (test/dev-branch)', calls[2])
        self.assertIn('ARCHS=arm64 ONLY_ACTIVE_ARCH=YES', calls[2])
        self.assertIn('open -n ', calls[-1])
        self.assertIn('-test_2Fdev-branch', calls[-1])
        self.assertIn("Building Mac branch 'test/dev-branch'", result.stdout)
        first_app = calls[-1]
        app_paths = {first_app}
        for branch in ('test_2Fdev-branch', 'test%2Fdev-branch'):
            subprocess.run(['git', '-C', str(self.root), 'symbolic-ref', 'HEAD',
                            'refs/heads/' + branch], check=True)
            self.log.unlink()
            result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM')
            self.assertEqual(result.returncode, 0, result.stderr)
            app_path = self.calls().splitlines()[-1]
            self.assertNotIn('%', app_path)
            self.assertNotIn(app_path, app_paths)
            app_paths.add(app_path)
        subprocess.run(['git', '-C', str(self.root), 'symbolic-ref', 'HEAD',
                        'refs/heads/test-dev-branch'], check=True)
        self.log.unlink()
        result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(first_app, self.calls().splitlines()[-1])
        self.log.unlink()
        result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM', RUNNING='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Quit the remaining aniCe copies', result.stderr)
        self.assertEqual(self.calls(), 'osascript\n')
        self.log.unlink()
        result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM',
                              SIGNATURE_AUTHORITY='Developer ID Application: Wrong Type')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith('open ') for line in self.calls().splitlines()))

    def test_intel_mac_is_rejected_before_build_or_launch(self):
        self.tool('uname', 'case "$1" in -s) echo Darwin;; -m) echo x86_64;; esac')
        result = self.run_dev('mac', ANICE_DEVELOPMENT_TEAM='TESTTEAM')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Apple Silicon and a native arm64 shell', result.stderr)
        self.assertEqual(self.calls(), '')

    def test_invalid_arguments_and_help(self):
        self.assertEqual(self.run_dev('--help').returncode, 0)
        self.assertNotEqual(self.run_dev('android', '--serial').returncode, 0)
        self.assertNotEqual(self.run_dev('mac', '--serial', 'phone').returncode, 0)
        self.assertEqual(self.calls(), '')

    def test_android_preview_uses_an_isolated_package_on_an_explicit_emulator(self):
        tool = self.root / 'sdk/build-tools/36.0.0/aapt'
        tool.parent.mkdir(parents=True)
        tool.write_text('#!/bin/bash\nprintf "package: name=\\047%s\\047 versionCode=\\04790021\\047\\n" "${APK_PACKAGE:-io.github.anisharyal09.anice.preview}"\n')
        tool.chmod(0o755)
        result = self.run_dev('android', '--preview', '--serial', 'emulator-5554',
                              DEVICES='phone\tdevice\nemulator-5554\tdevice')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-PanicePreview=true', (self.root / 'gradle-args').read_text())
        self.assertIn('-s emulator-5554 install -r ', self.calls())
        self.assertIn('-s emulator-5554 shell am start -W -n io.github.anisharyal09.anice.preview/io.github.anisharyal09.anice.MainActivity', self.calls())
        self.assertNotIn('-s phone ', self.calls())
        self.log.unlink()
        result = self.run_dev('android', '--preview', '--serial', 'emulator-5554',
                              DEVICES='emulator-5554\tdevice', APK_PACKAGE='io.github.anisharyal09.anice')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('install -r ', self.calls())

    def test_preview_never_builds_or_installs_on_a_physical_phone(self):
        for args in (('--serial', 'phone'), ()):
            result = self.run_dev('android', '--preview', *args, DEVICES='phone\tdevice')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), '')
        result = self.run_dev('android', '--preview', '--serial', 'emulator-5554',
                              DEVICES='emulator-5554\tdevice', EMULATOR_HARDWARE='samsung')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), '')

    def test_mac_preview_does_not_quit_production_or_load_its_signing_file(self):
        self.tool('uname', 'case "$1" in -s) echo Darwin;; -m) echo arm64;; esac')
        self.tool('osascript', 'echo osascript >> "$CALLS"; exit 1')
        self.tool('pgrep', 'echo pgrep >> "$CALLS"; exit 0')
        self.tool('python3', 'echo python3 >> "$CALLS"')
        self.tool('xcodebuild', 'printf "xcodebuild %s\\n" "$*" >> "$CALLS"')
        self.tool('codesign', '''echo codesign >> "$CALLS"
if [ "$1" = -dv ]; then
  echo "Identifier=${SIGNATURE_IDENTIFIER:-io.github.anisharyal09.anice.preview}" >&2
  echo "Signature=adhoc" >&2
fi''')
        self.tool('open', 'printf "open %s\\n" "$*" >> "$CALLS"')
        (self.root / 'scripts/dev.local.sh').write_text('echo loaded-signing >> "$CALLS"\nexit 1\n')
        result = self.run_dev('mac', '--preview')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertNotIn('osascript', calls)
        self.assertNotIn('pgrep', calls)
        self.assertNotIn('loaded-signing', calls)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER=io.github.anisharyal09.anice.preview', calls)
        self.assertIn('ANICE_PREVIEW', calls)
        self.assertIn('build/preview-mac/', calls)
        self.assertIn('aniCePreview.app', calls)
        self.log.unlink()
        result = self.run_dev('mac', '--preview', SIGNATURE_IDENTIFIER='io.github.anisharyal09.anice')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('open -n ', self.calls())


if __name__ == '__main__':
    unittest.main()
