# SPDX-License-Identifier: GPL-3.0-or-later
# Injects forbidden dependencies, broken links and missing/duplicate Xcode source membership.
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('structure', Path(__file__).with_name('check-structure.py'))
structure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(structure)

class StructureTests(unittest.TestCase):
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
