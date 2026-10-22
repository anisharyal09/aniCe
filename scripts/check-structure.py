#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks native dependency direction, local documentation targets and explicit Xcode source membership.
from pathlib import Path
from collections import Counter
import json
import platform
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent


def load_project(path, engine=None):
    # Both parsers feed the same membership checks; Linux must still inspect the Xcode project.
    engine = engine or ('plutil' if platform.system() == 'Darwin' else 'openstep')
    if engine == 'plutil':
        project = json.loads(subprocess.check_output(
            ['plutil', '-convert', 'json', '-o', '-', str(path)]))
    elif engine == 'openstep':
        try:
            from openstep_parser import OpenStepDecoder
        except ImportError as error:
            raise RuntimeError(
                'Portable Xcode project checks require openstep-parser; install '
                'scripts/requirements.txt with the Python interpreter running this check.') from error
        with path.open(encoding='utf-8') as stream:
            try:
                text = stream.read()
                decoder = OpenStepDecoder()
                start = text.index('{') if text.startswith('//') else decoder._parse_padding(text, 0)
                # The pinned parser's public API discards the ending offset and accepts trailing garbage.
                project, end = decoder._parse_dictionary(text, start)
                if not re.fullmatch(r'(?:\s|/\*.*?\*/|//[^\r\n]*)*', text[end:], re.S):
                    raise ValueError('Unexpected content after the Xcode project dictionary')
            except Exception as error:
                # The pinned parser raises bare Exception or IndexError for invalid syntax.
                if type(error) not in (Exception, IndexError):
                    raise
                raise ValueError('Invalid OpenStep project: ' + str(error)) from error
    else:
        raise ValueError('Unknown project parser: ' + engine)
    if not isinstance(project, dict) or not isinstance(project.get('objects'), dict) or not project.get('rootObject'):
        raise ValueError('Xcode project is missing its objects or rootObject')
    return project


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
    # Xcode groups resolve file references relative to their parents or the project source root.
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
        # The playback helper is compiled separately; its sources belong in build inputs, not app membership.
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
    try:
        project = load_project(ROOT / 'apps/macos/aniCe.xcodeproj/project.pbxproj')
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print('Cannot read Xcode project: ' + str(error), file=sys.stderr)
        return 1
    tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '*.md'], cwd=ROOT, text=True).splitlines()
    docs = [ROOT / name for name in tracked if not name.startswith('.agents/') and (ROOT / name).is_file()]
    errors = dependency_errors(ROOT) + documentation_errors(ROOT, docs) + membership_errors(ROOT, project)
    for error in errors: print(error)
    if errors: return 1
    print('Dependency direction, documentation links and Xcode membership passed.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
