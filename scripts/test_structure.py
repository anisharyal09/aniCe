# SPDX-License-Identifier: GPL-3.0-or-later
# Injects forbidden dependencies, broken links and missing/duplicate Xcode source membership.
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('structure', Path(__file__).with_name('check-structure.py'))
structure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(structure)

class StructureTests(unittest.TestCase):
    # Temporary broken repositories exercise rejection rules; the real project checks host parsing.
    def test_host_parser_preserves_real_project_membership(self):
        project = structure.load_project(structure.ROOT / 'apps/macos/aniCe.xcodeproj/project.pbxproj')
        self.assertGreaterEqual(len(project['objects']), 100)
        self.assertEqual(structure.membership_errors(structure.ROOT, project), [])
        try:
            import openstep_parser
        except ImportError:
            return
        openstep_proj = structure.load_project(structure.ROOT / 'apps/macos/aniCe.xcodeproj/project.pbxproj', engine='openstep')
        # Matching object IDs alone would miss changed paths, types or nested build references.
        self.assertEqual(project, openstep_proj)
        self.assertEqual(structure.membership_errors(structure.ROOT, openstep_proj), [])

    def test_linux_never_invokes_plutil_and_missing_dependency_is_actionable(self):
        # Simulate an unprepared Linux host without depending on this machine's installed packages.
        with patch.object(structure.platform, 'system', return_value='Linux'), \
             patch.object(structure.subprocess, 'check_output', side_effect=AssertionError('plutil invoked')), \
             patch.dict('sys.modules', {'openstep_parser': None}):
            with self.assertRaisesRegex(RuntimeError, 'scripts/requirements.txt'):
                structure.load_project(Path('project.pbxproj'))

    def test_malformed_project_is_rejected_by_each_available_engine(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'broken.pbxproj'
            engines = ['plutil'] if structure.platform.system() == 'Darwin' else ['openstep']
            try:
                import openstep_parser
                if 'openstep' not in engines:
                    engines.append('openstep')
            except ImportError:
                pass
            for content in ('', '{ objects = {', '{ objects = 1; }',
                            '{ objects = {}; rootObject = root; } trailing garbage'):
                path.write_text(content)
                for engine in engines:
                    with self.subTest(content=content, engine=engine):
                        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                            structure.load_project(path, engine)

    def test_project_trailing_comments_remain_valid(self):
        engines = ['plutil'] if structure.platform.system() == 'Darwin' else ['openstep']
        if importlib.util.find_spec('openstep_parser') is not None and 'openstep' not in engines:
            engines.append('openstep')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'comments.pbxproj'
            for suffix in ('\n', ' /* first */ /* second */\n', ' // first\n // second\n'):
                path.write_text('{ objects = {}; rootObject = root; }' + suffix)
                for engine in engines:
                    with self.subTest(suffix=suffix, engine=engine):
                        self.assertEqual(structure.load_project(path, engine), {'objects': {}, 'rootObject': 'root'})

    def test_dependency_direction_and_link_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            infra = root / 'apps/android/app/src/main/java/io/github/anisharyal09/anice/infrastructure/connections'
            infra.mkdir(parents=True)
            source = infra / 'Owner.kt'
            source.write_text('import app.features.nowplaying.MediaController\n')
            self.assertEqual(len(structure.dependency_errors(root)), 1)
            source.write_text('import app.infrastructure.session.SessionConnection\n')
            self.assertEqual(structure.dependency_errors(root), [])
            doc = root / 'README.md'; target = root / 'valid.md'; target.write_text('')
            doc.write_text('[ok](valid.md#part) [bad](missing.md) [web](https://example.com)')
            self.assertEqual(len(structure.documentation_errors(root, [doc])), 1)
            doc.write_text('[ok](valid.md#part)')
            self.assertEqual(structure.documentation_errors(root, [doc]), [])

    def test_missing_and_duplicate_membership(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'apps/macos/aniCe/Owner.swift'
            source.parent.mkdir(parents=True); source.write_text('')
            # A minimal Xcode reference graph makes each missing or duplicate edge observable.
            objects = {'project': {'mainGroup': 'group'}, 'group': {'isa': 'PBXGroup', 'children': ['file']},
                'file': {'isa': 'PBXFileReference', 'path': 'aniCe/Owner.swift', 'sourceTree': 'SOURCE_ROOT'},
                'target': {'isa': 'PBXNativeTarget', 'name': 'aniCe', 'buildPhases': ['phase']},
                'phase': {'isa': 'PBXSourcesBuildPhase', 'files': ['member']}, 'member': {'fileRef': 'file'}}
            project = {'rootObject': 'project', 'objects': objects}
            self.assertEqual(structure.membership_errors(root, project), [])
            objects['phase']['files'] = []
            self.assertEqual(len(structure.membership_errors(root, project)), 1)
            objects['phase']['files'] = ['member', 'member']
            self.assertTrue(any('duplicate' in error for error in structure.membership_errors(root, project)))
            helper = root / 'apps/macos/aniCe/Features/NowPlaying/Adapter/NowPlayingAdapter.swift'
            helper.parent.mkdir(parents=True); helper.write_text('')
            self.assertTrue(any('helper: missing build input' in error for error in structure.membership_errors(root, project)))
            objects['helperphase'] = {'isa': 'PBXShellScriptBuildPhase', 'inputPaths': ['$(SRCROOT)/aniCe/Features/NowPlaying/Adapter/NowPlayingAdapter.swift']}
            self.assertFalse(any('helper: missing build input' in error for error in structure.membership_errors(root, project)))
            helper.unlink()
            source.unlink()
            self.assertTrue(any('missing source' in error for error in structure.membership_errors(root, project)))

if __name__ == '__main__': unittest.main()
