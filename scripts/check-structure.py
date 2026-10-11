#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks native dependency direction, local documentation targets and explicit Xcode source membership.
from pathlib import Path
from collections import Counter
import json
import re
import subprocess
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent


def dependency_errors(root):
    errors = []
    android = root / 'apps/android/app/src/main/java/io/github/anisharyal09/anice/infrastructure'
    for path in android.rglob('*.kt'):
        if re.search(r'^import .*\.features\.', path.read_text(), re.M):
            errors.append(f'{path.relative_to(root)}: infrastructure imports feature presentation')
    for path in (root / 'apps/macos/aniCe/Infrastructure').rglob('*.swift'):
        if re.search(r'\b(MacPlaybackModel|MediaMessage|MediaView)\b', path.read_text()):
            errors.append(f'{path.relative_to(root)}: infrastructure depends on playback')
    return errors


def documentation_errors(root, paths):
    errors = []
    for path in paths:
        for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
            target = target.strip().strip('<>')
            if re.match(r'[a-zA-Z][\w+.-]*:|#', target):
                continue
            target = unquote(target.split('#')[0])
            if target and not (path.parent / target).exists():
                errors.append(f'{path.relative_to(root)}: missing link {target}')
    return errors


def membership_errors(root, project):
    root = root.resolve()
    objects = project['objects']; paths = {}; errors = []
    base = root / 'apps/macos'
    def walk(key, parent):
        obj = objects[key]
        tree = obj.get('sourceTree', '<group>')
        directory = base if tree == 'SOURCE_ROOT' else parent
        path = directory / obj.get('path', '')
        if obj['isa'] == 'PBXFileReference':
            paths[key] = path.resolve()
        for child in obj.get('children', []):
            walk(child, path)
    walk(objects[project['rootObject']]['mainGroup'], base)
    for target in objects.values():
        if target.get('isa') != 'PBXNativeTarget' or target.get('name') not in ('aniCe', 'aniCeTests'):
            continue
        inventory = []
        for phase in target['buildPhases']:
            if objects[phase]['isa'] == 'PBXSourcesBuildPhase':
                for member in objects[phase]['files']:
                    ref = objects[member]['fileRef']
                    path = paths.get(ref)
                    if path is None or not path.is_file(): errors.append(f'{target["name"]}: missing source {ref}')
                    else: inventory.append(path)
        counts = Counter(inventory)
        for path, count in counts.items():
            if count != 1: errors.append(f'{target["name"]}: duplicate source {path.relative_to(root)}')
        folder = base / target['name']
        helper_inputs = {base / 'aniCe/Features/NowPlaying/Adapter' / name for name in ('NowPlayingAdapter.swift', 'NowPlayingSelection.swift')}
        declared_inputs = {value for obj in objects.values() if obj.get('isa') == 'PBXShellScriptBuildPhase' for value in obj.get('inputPaths', [])}
        for path in folder.rglob('*.swift'):
            if path == base / 'aniCeTests/NowPlaying/AdapterChecks.swift':
                if counts[path.resolve()] != 0: errors.append('standalone adapter checks must not enter hosted test membership')
                continue
            if path in helper_inputs:
                if '$(SRCROOT)/' + str(path.relative_to(base)) not in declared_inputs:
                    errors.append(f'helper: missing build input {path.relative_to(root)}')
                if counts[path.resolve()] != 0: errors.append(f'helper: unexpected app membership {path.relative_to(root)}')
                continue
            if counts[path.resolve()] != 1: errors.append(f'{target["name"]}: missing membership {path.relative_to(root)}')
    return errors


def main():
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'apps/macos/aniCe.xcodeproj/project.pbxproj')]))
    tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '*.md'], cwd=ROOT, text=True).splitlines()
    docs = [ROOT / name for name in tracked if not name.startswith('.agents/') and (ROOT / name).is_file()]
    errors = dependency_errors(ROOT) + documentation_errors(ROOT, docs) + membership_errors(ROOT, project)
    for error in errors: print(error)
    if errors: return 1
    print('Dependency direction, documentation links and Xcode membership passed.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
