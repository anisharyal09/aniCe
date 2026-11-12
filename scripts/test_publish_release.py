# SPDX-License-Identifier: GPL-3.0-or-later
# Ensures release publishing fails before mutations for unsafe source or version states.
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import publish_release


class PublishReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        for name in publish_release.NAMES:
            (Path(self.temp.name) / name).write_bytes(b'apk')
        self.commit = 'a' * 40
        self.argv = ['publish_release.py', 'v0.4.0', self.commit, self.temp.name]
        self.env = {'GITHUB_REPOSITORY': 'anisharyal09/aniCe', 'ANICE_AAPT': '/test/aapt'}

    def test_rejects_moved_tag_before_mutation(self):
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', return_value=json.dumps({'sha': 'b' * 40})), \
             mock.patch.object(publish_release, 'gh') as gh:
            with self.assertRaisesRegex(ValueError, 'tag no longer'):
                publish_release.main()
            gh.assert_not_called()

    def test_refuses_to_overwrite_published_release(self):
        releases = [[{'tag_name': 'v0.4.0', 'draft': False, 'assets': []}]]
        outputs = [json.dumps({'sha': self.commit}), json.dumps(releases)]
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs), \
             mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
             mock.patch.object(publish_release, 'gh') as gh:
            with self.assertRaisesRegex(ValueError, 'already exists'):
                publish_release.main()
            gh.assert_not_called()

    def test_rejects_non_increasing_published_apk_code(self):
        releases = [[{'tag_name': 'v0.3.0', 'draft': False, 'assets': [
            {'name': 'aniCe-android.apk', 'id': 7, 'size': 3}]}]]
        outputs = [json.dumps({'sha': self.commit}), json.dumps(releases)]
        def download(*args, **kwargs):
            kwargs['stdout'].write(b'old')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs), \
             mock.patch.object(publish_release, 'apk_code', side_effect=[(40099, '0.4.0'), (40099, '0.3.0')]), \
             mock.patch.object(publish_release, 'gh', side_effect=download) as gh:
            with self.assertRaisesRegex(ValueError, 'not greater'):
                publish_release.main()
            self.assertEqual(gh.call_count, 1)
            self.assertEqual(gh.call_args.args[0], 'api')

    def test_rejects_extra_draft_assets(self):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        assets.append({'name': 'aniCe-installer.dmg', 'id': 9, 'size': 3})
        draft = {'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft)]
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs), \
             mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
             mock.patch.object(publish_release, 'gh') as gh:
            with self.assertRaisesRegex(ValueError, 'unexpected assets'):
                publish_release.main()
            gh.assert_not_called()

    def test_refuses_publication_if_an_extra_asset_appears(self):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        latest = {**draft, 'assets': assets + [{'name': 'extra.txt', 'id': 99, 'size': 3}]}
        outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                   json.dumps({'sha': self.commit}), json.dumps(latest)]
        def call(*args, **kwargs):
            if args[0] == 'api':
                kwargs['stdout'].write(b'apk')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs), \
             mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
             mock.patch.object(publish_release, 'gh', side_effect=call) as gh:
            with self.assertRaisesRegex(ValueError, 'Draft changed'):
                publish_release.main()
            self.assertFalse(any(call.args[0] == 'release' for call in gh.call_args_list))

    def test_resumes_matching_draft_after_verifying_both_assets(self):
        self.check_draft_resume(change_asset=False)

    def test_refuses_publication_if_verified_asset_changes(self):
        self.check_draft_resume(change_asset=True)

    def check_draft_resume(self, change_asset):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        latest = {**draft, 'assets': [dict(item) for item in assets]}
        if change_asset:
            latest['assets'][1]['id'] = 999
        outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                   json.dumps({'sha': self.commit}), json.dumps(latest)]
        def call(*args, **kwargs):
            if args[0] == 'api':
                kwargs['stdout'].write(b'apk')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs), \
             mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
             mock.patch.object(publish_release, 'gh', side_effect=call) as gh:
            if change_asset:
                with self.assertRaisesRegex(ValueError, 'Draft changed'):
                    publish_release.main()
                self.assertFalse(any(call.args[0] == 'release' for call in gh.call_args_list))
            else:
                publish_release.main()
                self.assertEqual(gh.call_args.args[:2], ('release', 'edit'))
                self.assertEqual(gh.call_args_list[0].args[0], 'api')
                self.assertEqual(gh.call_args_list[1].args[0], 'api')


if __name__ == '__main__':
    unittest.main()
