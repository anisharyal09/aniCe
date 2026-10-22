#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks experiment launch isolation, missing-build failures and argument forwarding without audio access.
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

LAUNCHER = Path(__file__).with_name('run-scrcpy-client-audio.sh')
REVISION = '0066c8425827682c4791232f0e248d20e53b7ee2'


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='anice audio launcher ')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'scripts').mkdir()
        self.launcher = self.root / 'scripts' / LAUNCHER.name
        shutil.copy2(LAUNCHER, self.launcher)
        self.source = self.root / 'build/scrcpy-client-audio'
        self.environment = dict(os.environ)

    def checkout(self, revision=REVISION, server=True):
        (self.source / '.git').mkdir(parents=True)
        (self.source / 'x/app').mkdir(parents=True)
        (self.source / 'x/server').mkdir(parents=True)
        binary = self.source / 'x/app/scrcpy'
        binary.write_text('#!/bin/sh\nprintf "%s\\n" "$SCRCPY_SERVER_PATH" "$SCRCPY_ICON_DIR" "$@"\n')
        binary.chmod(0o755)
        if server:
            (self.source / 'x/server/scrcpy-server').write_text('fixture')
        tools = self.root / 'tools'
        tools.mkdir()
        git = tools / 'git'
        git.write_text('#!/bin/sh\nprintf "%s\\n" ' + revision + '\n')
        git.chmod(0o755)
        self.environment['PATH'] = str(tools) + os.pathsep + self.environment['PATH']

    def run_launcher(self, *arguments):
        return subprocess.run(['sh', str(self.launcher), *arguments], env=self.environment,
                              text=True, capture_output=True, timeout=5)

    def test_missing_checkout_does_not_start_audio(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 2)
        self.assertIn('Missing experimental checkout', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_wrong_revision_and_missing_server_do_not_launch(self):
        self.checkout(revision='wrong-revision', server=False)
        result = self.run_launcher()
        self.assertEqual(result.returncode, 2)
        self.assertIn('Unexpected scrcpy revision', result.stderr)
        self.assertEqual(result.stdout, '')
        (self.root / 'tools/git').write_text('#!/bin/sh\nprintf "%s\\n" ' + REVISION + '\n')
        result = self.run_launcher()
        self.assertEqual(result.returncode, 2)
        self.assertIn('Build both', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_matching_server_resources_and_arguments_remain_isolated(self):
        self.checkout()
        arguments = ['-s', '192.168.100.10:12345', '--client-audio-source', 'file:///a b.wav']
        result = self.run_launcher(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.source / 'x/server/scrcpy-server'),
                                                     str(self.source / 'app/data'), *arguments])


if __name__ == '__main__':
    unittest.main()
