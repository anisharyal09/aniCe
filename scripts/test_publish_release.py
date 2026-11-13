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
        ci = mock.patch.object(publish_release, 'require_ci')
        self.require_ci = ci.start()
        self.addCleanup(ci.stop)

    def test_release_preflight_handles_pagination_conflicts_and_matching_drafts(self):
        marker = f'<!-- anice-source:{self.commit} -->'
        good = {'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                'body': marker, 'assets': []}
        for draft, accepted in ((good, True), ({**good, 'draft': False}, False),
                ({**good, 'body': '<!-- anice-source:wrong -->'}, False),
                ({**good, 'prerelease': True}, False),
                ({**good, 'assets': [{'name': 'extra.txt'}]}, False),
                ({**good, 'assets': [None]}, False)):
            with self.subTest(draft=draft), mock.patch.object(publish_release.subprocess, 'check_output',
                    return_value=json.dumps([[], [draft]])) as api, mock.patch.object(publish_release, 'gh') as gh:
                if accepted:
                    releases, existing, actual_marker = publish_release.check_release_state(
                        'anisharyal09/aniCe', 'v0.4.0', self.commit)
                    self.assertEqual(existing, draft)
                    self.assertEqual(actual_marker, marker)
                else:
                    with self.assertRaises(ValueError):
                        publish_release.check_release_state('anisharyal09/aniCe', 'v0.4.0', self.commit)
                gh.assert_not_called()
                self.assertIn('--paginate', api.call_args.args[0])

    def test_rejects_missing_empty_oversized_or_wrong_version_assets_before_mutation(self):
        for kind in ('missing', 'empty', 'oversized', 'wrong-version'):
            with self.subTest(kind=kind):
                path = Path(self.temp.name) / publish_release.NAMES[0]
                path.write_bytes(b'apk')
                if kind == 'missing':
                    path.unlink()
                elif kind == 'empty':
                    path.write_bytes(b'')
                elif kind == 'oversized':
                    with path.open('wb') as file:
                        file.truncate(publish_release.MAX_BYTES + 1)
                with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
                        mock.patch.object(publish_release.subprocess, 'check_output', return_value=json.dumps({'sha': self.commit})), \
                        mock.patch.object(publish_release, 'apk_code', return_value=(1, 'wrong')), \
                        mock.patch.object(publish_release, 'gh') as gh:
                    with self.assertRaises(ValueError):
                        publish_release.main()
                    gh.assert_not_called()

    def test_corrupt_download_or_moved_tag_never_reports_verified_draft(self):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        for corrupt in (True, False):
            outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                       json.dumps({'sha': 'b' * 40})]
            def download(*args, **kwargs):
                kwargs['stdout'].write(b'bad' if corrupt else b'apk')
            with self.subTest(corrupt=corrupt), mock.patch.object(sys, 'argv', self.argv), \
                    mock.patch.dict(os.environ, self.env), \
                    mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs), \
                    mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
                    mock.patch.object(publish_release, 'gh', side_effect=download) as gh:
                with self.assertRaisesRegex(ValueError, 'digest mismatch' if corrupt else 'tag no longer'):
                    publish_release.main()
                self.assertFalse(any(call.args[0] == 'release' for call in gh.call_args_list))

    def test_preflight_rejects_non_increasing_published_versions_but_ignores_drafts(self):
        for previous, draft, accepted in (('v0.3.0', False, True), ('v0.4.0', False, False),
                ('v0.4.1-alpha.1', False, False), ('v1.0.0', True, True), ('legacy', False, True)):
            release = {'tag_name': previous, 'draft': draft, 'assets': [{'name': publish_release.NAMES[0]}]}
            with self.subTest(previous=previous, draft=draft), mock.patch.object(
                    publish_release.subprocess, 'check_output', return_value=json.dumps([[release]])):
                if accepted:
                    publish_release.check_release_state('anisharyal09/aniCe', 'v0.4.0-beta.1', self.commit)
                else:
                    with self.assertRaisesRegex(ValueError, 'not greater'):
                        publish_release.check_release_state('anisharyal09/aniCe', 'v0.4.0-beta.1', self.commit)

    def test_requires_ci_before_creating_or_uploading_a_draft(self):
        self.require_ci.side_effect = ValueError('CI did not succeed')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', return_value=json.dumps({'sha': self.commit})), \
             mock.patch.object(publish_release, 'gh') as gh:
            with self.assertRaisesRegex(ValueError, 'CI did not succeed'):
                publish_release.main()
            gh.assert_not_called()
            self.require_ci.assert_called_once_with('anisharyal09/aniCe', self.commit)

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

    def test_first_beta_creates_and_verifies_a_draft_without_publishing(self):
        self.argv[1] = 'v0.4.0-beta.1'
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'tag_name': self.argv[1], 'draft': True, 'prerelease': True,
                 'body': f'<!-- anice-source:{self.commit} -->\n\n## What\'s Changed\n\n* First beta.',
                 'assets': [], 'id': 1}
        complete = {**draft, 'assets': assets}
        # subprocess.check_output sequence:
        # 1. check_tag_commit, 2. check_release_state pagination (empty),
        # 3. Create API response -> {'id': 1}, 4. find_release by id -> draft,
        # 5. find_release after apk upload, 6. find_release after mac upload,
        # 7. check_tag_commit, 8. final find_release
        outputs = [json.dumps({'sha': self.commit}), json.dumps([[]]),
                   json.dumps({'id': 1}), json.dumps(draft),
                   json.dumps({**draft, 'assets': assets[:1]}), json.dumps(complete),
                   json.dumps({'sha': self.commit}), json.dumps(complete)]
        def call(*args, **kwargs):
            if args[0] == 'api':
                kwargs['stdout'].write(b'apk')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs) as check_output, \
             mock.patch.object(publish_release, 'apk_code', return_value=(40021, '0.4.0-beta.1')), \
             mock.patch.object(publish_release, 'gh', side_effect=call) as gh:
            publish_release.main()
            commands = [invocation.args[0] for invocation in check_output.call_args_list]
            create = next(command for command in commands if command[:4] ==
                          ['gh', 'api', '--method', 'POST'])
            self.assertEqual(create, [
                'gh', 'api', '--method', 'POST', 'repos/anisharyal09/aniCe/releases',
                '-f', f'tag_name={self.argv[1]}', '-f', f'name={self.argv[1]}',
                '-f', f'body=<!-- anice-source:{self.commit} -->',
                '-F', 'draft=true', '-F', 'prerelease=true', '-F', 'generate_release_notes=true',
            ])
            self.assertIn(['gh', 'api', 'repos/anisharyal09/aniCe/releases/1'], commands)
            mutations = [call.args for call in gh.call_args_list if call.args[0] == 'release']
            self.assertEqual([call[1] for call in mutations], ['upload', 'upload'])
            self.assertEqual(sum(call.args[0] == 'api' for call in gh.call_args_list), 2)

    def test_refuses_publication_if_verified_asset_changes(self):
        self.check_draft_resume(change_asset=True)

    def test_marker_only_drafts_get_notes_without_overwriting_concurrent_edits(self):
        marker = f'<!-- anice-source:{self.commit} -->'
        notes = "## What's Changed\n\n* Improve release preparation."
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        for original, manual in ((marker, False), ('\n ' + marker + ' \n', False), (marker, True)):
            draft = {'id': 7, 'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                     'body': original, 'assets': assets}
            refreshed = {**draft, 'body': marker + '\n\nMaintainer description.'} if manual else draft
            updated = {**draft, 'body': marker + '\n\n' + notes}
            outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                       json.dumps({'sha': self.commit}), json.dumps(draft), json.dumps({'body': notes}),
                       json.dumps({'sha': self.commit}), json.dumps(refreshed)]
            if not manual:
                outputs.append(json.dumps(updated))
            outputs.append(json.dumps({'sha': self.commit}))
            def download(*args, **kwargs):
                kwargs['stdout'].write(b'apk')
            with self.subTest(original=original, manual=manual), mock.patch.object(sys, 'argv', self.argv), \
                    mock.patch.dict(os.environ, self.env), \
                    mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs) as api, \
                    mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
                    mock.patch.object(publish_release, 'gh', side_effect=download) as gh:
                publish_release.main()
                commands = [call.args[0] for call in api.call_args_list]
                self.assertEqual(len(commands), len(outputs))
                self.assertIn(['gh', 'api', '--method', 'POST',
                               'repos/anisharyal09/aniCe/releases/generate-notes',
                               '-f', 'tag_name=v0.4.0', '-f', f'target_commitish={self.commit}'], commands)
                patches = [command for command in commands if command[:4] == ['gh', 'api', '--method', 'PATCH']]
                self.assertEqual(patches, [] if manual else [
                    ['gh', 'api', '--method', 'PATCH', 'repos/anisharyal09/aniCe/releases/7',
                     '-f', f'body={updated["body"]}']])
                self.assertEqual(gh.call_count, 2)
                self.assertFalse(any(call.args[0] == 'release' for call in gh.call_args_list))

    def test_rejects_empty_or_invalid_generated_descriptions_before_patch(self):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'id': 7, 'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        for notes in (None, [], {}, {'body': None}, {'body': ''}, {'body': ' \n\t'}, {'body': 42},
                      {'body': draft['body']}):
            outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                       json.dumps({'sha': self.commit}), json.dumps(draft), json.dumps(notes)]
            def download(*args, **kwargs):
                kwargs['stdout'].write(b'apk')
            with self.subTest(notes=notes), mock.patch.object(sys, 'argv', self.argv), \
                    mock.patch.dict(os.environ, self.env), \
                    mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs) as api, \
                    mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
                    mock.patch.object(publish_release, 'gh', side_effect=download):
                with self.assertRaisesRegex(ValueError, 'Generated release description is empty or invalid'):
                    publish_release.main()
                self.assertFalse(any(call.args[0][:4] == ['gh', 'api', '--method', 'PATCH']
                                     for call in api.call_args_list))

    def test_rechecks_source_and_draft_state_before_description_update(self):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'id': 7, 'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        changed_assets = [{**assets[0], 'id': 99}, assets[1]]
        cases = [({'sha': self.commit}, {**draft, **change}, 'Draft changed') for change in (
            {'draft': False}, {'tag_name': 'v0.4.1'}, {'prerelease': True},
            {'body': '<!-- anice-source:wrong -->'}, {'assets': changed_assets})]
        cases.append(({'sha': 'b' * 40}, None, 'Remote tag no longer'))
        for ref, refreshed, error in cases:
            outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                       json.dumps({'sha': self.commit}), json.dumps(draft), json.dumps({'body': 'Release notes.'}),
                       json.dumps(ref)]
            if refreshed:
                outputs.append(json.dumps(refreshed))
            def download(*args, **kwargs):
                kwargs['stdout'].write(b'apk')
            with self.subTest(ref=ref, refreshed=refreshed), mock.patch.object(sys, 'argv', self.argv), \
                    mock.patch.dict(os.environ, self.env), \
                    mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs) as api, \
                    mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
                    mock.patch.object(publish_release, 'gh', side_effect=download):
                with self.assertRaisesRegex(ValueError, error):
                    publish_release.main()
                self.assertFalse(any(call.args[0][:4] == ['gh', 'api', '--method', 'PATCH']
                                     for call in api.call_args_list))

    def test_refuses_verified_status_if_description_update_is_not_saved(self):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'id': 7, 'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->', 'assets': assets}
        outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                   json.dumps({'sha': self.commit}), json.dumps(draft), json.dumps({'body': 'Release notes.'}),
                   json.dumps({'sha': self.commit}), json.dumps(draft), json.dumps(draft)]
        def download(*args, **kwargs):
            kwargs['stdout'].write(b'apk')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
                mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs) as api, \
                mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
                mock.patch.object(publish_release, 'gh', side_effect=download):
            with self.assertRaisesRegex(ValueError, 'Draft release description was not saved'):
                publish_release.main()
            self.assertEqual(sum(call.args[0][:4] == ['gh', 'api', '--method', 'PATCH']
                                 for call in api.call_args_list), 1)

    def check_draft_resume(self, change_asset):
        assets = [{'name': name, 'id': i + 1, 'size': 3} for i, name in enumerate(publish_release.NAMES)]
        draft = {'tag_name': 'v0.4.0', 'draft': True, 'prerelease': False,
                 'body': f'<!-- anice-source:{self.commit} -->\n\nMaintainer description.', 'assets': assets}
        latest = {**draft, 'assets': [dict(item) for item in assets]}
        if change_asset:
            latest['assets'][1]['id'] = 999
        outputs = [json.dumps({'sha': self.commit}), json.dumps([[draft]]), json.dumps(draft),
                   json.dumps({'sha': self.commit}), json.dumps(latest)]
        def call(*args, **kwargs):
            if args[0] == 'api':
                kwargs['stdout'].write(b'apk')
        with mock.patch.object(sys, 'argv', self.argv), mock.patch.dict(os.environ, self.env), \
             mock.patch.object(publish_release.subprocess, 'check_output', side_effect=outputs) as api, \
             mock.patch.object(publish_release, 'apk_code', return_value=(40099, '0.4.0')), \
             mock.patch.object(publish_release, 'gh', side_effect=call) as gh:
            if change_asset:
                with self.assertRaisesRegex(ValueError, 'Draft changed'):
                    publish_release.main()
                self.assertFalse(any(call.args[0] == 'release' for call in gh.call_args_list))
            else:
                publish_release.main()
                self.assertFalse(any(call.args[0] == 'release' for call in gh.call_args_list))
                self.assertEqual(gh.call_args_list[0].args[0], 'api')
                self.assertEqual(gh.call_args_list[1].args[0], 'api')
                self.assertFalse(any('--method' in call.args[0] for call in api.call_args_list))


class ReleaseCITest(unittest.TestCase):
    def test_only_latest_successful_main_push_for_exact_commit_is_accepted(self):
        commit = 'a' * 40
        good = {'id': 1, 'head_sha': commit, 'head_branch': 'main', 'event': 'push',
                'status': 'completed', 'conclusion': 'success'}
        cases = [([], False), ([good], True),
                 ([{**good, 'head_sha': 'b' * 40}], False),
                 ([{**good, 'head_branch': 'feat/test'}], False),
                 ([{**good, 'event': 'pull_request'}], False)]
        for conclusion in ('failure', 'cancelled', 'skipped', None):
            cases.append(([good, {**good, 'id': 2, 'conclusion': conclusion}], False))
        cases.append(([good, {**good, 'id': 2, 'status': 'in_progress'}], False))
        for runs, accepted in cases:
            with self.subTest(runs=runs), mock.patch.object(publish_release.subprocess, 'check_output',
                    return_value=json.dumps({'workflow_runs': runs})) as api:
                if accepted:
                    publish_release.require_ci('anisharyal09/aniCe', commit)
                else:
                    with self.assertRaises(ValueError):
                        publish_release.require_ci('anisharyal09/aniCe', commit)
                self.assertIn('/actions/workflows/ci.yml/runs?', api.call_args.args[0][-1])


if __name__ == '__main__':
    unittest.main()
