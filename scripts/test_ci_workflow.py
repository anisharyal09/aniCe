#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Policy tests for the GitHub Actions gate itself.

These tests parse the workflows instead of scanning one expected line.  They
exist to make the dangerous failures fail: an unpinned action, a mutable
runner, a write-scoped pull request, a silently skipped lane, or an aggregator
that accepts anything other than ``success``.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REQUIRED_JOBS = (
    "verify-ci-integrity",
    "verify-contracts",
    "verify-rust",
    "verify-android",
    "verify-macos",
)
REQUIRED_LANES = {
    "verify-ci-integrity": "ci-integrity",
    "verify-contracts": "contracts",
    "verify-rust": "rust",
    "verify-android": "android",
    "verify-macos": "macos",
}
PR_EVENTS = {"pull_request", "merge_group"}
SAFE_EVENTS = {"push", "pull_request", "merge_group", "workflow_dispatch", "schedule"}
FULL_SHA = re.compile(r"[0-9a-f]{40}")
FULL_DOCKER_DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")


def load_workflow(path):
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise AssertionError("%s must contain a YAML mapping" % path.name)
    # PyYAML implements YAML 1.1, where the unquoted key "on" resolves to True.
    if True in document:
        document["on"] = document.pop(True)
    return document


def workflow_paths():
    # actionlint checks both suffixes; the policy gate must not silently skip one.
    return sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])


def workflow_documents():
    return {path.name: load_workflow(path) for path in workflow_paths()}


def triggers(document):
    value = document.get("on")
    if isinstance(value, str):
        return {value}
    if isinstance(value, list):
        return set(value)
    if isinstance(value, dict):
        return set(value)
    return set()


def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key, child
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def step_runs(job):
    return [step.get("run", "") for step in job.get("steps", []) if step.get("run")]


class WorkflowPolicyTests(unittest.TestCase):
    def test_workflows_use_only_safe_events(self):
        documents = workflow_documents()
        self.assertTrue(documents)
        for name, document in documents.items():
            events = triggers(document)
            self.assertTrue(events, name)
            self.assertLessEqual(events, SAFE_EVENTS, name)
            self.assertNotIn("pull_request_target", events, name)
            self.assertNotIn("workflow_run", events, name)

    def test_pull_request_workflows_are_read_only_and_github_hosted(self):
        for name, document in workflow_documents().items():
            if not (triggers(document) & PR_EVENTS):
                continue
            self.assertEqual(document.get("permissions"), {"contents": "read"}, name)
            for job_name, job in document.get("jobs", {}).items():
                permissions = job.get("permissions")
                if permissions:
                    self.assertIsInstance(permissions, dict, "%s:%s" % (name, job_name))
                    for scope, access in permissions.items():
                        self.assertIn(access, ("read", "none"), "%s:%s:%s" % (name, job_name, scope))
                runner = job.get("runs-on")
                self.assertIsInstance(runner, str, "%s:%s" % (name, job_name))
                self.assertNotIn("self-hosted", runner)
                self.assertRegex(runner, r"^(ubuntu-24\.04|macos-\d+)$")
            for _, value in walk(document):
                if isinstance(value, str):
                    self.assertNotIn("secrets.", value, name)

    def test_every_job_has_a_timeout_and_never_uses_a_latest_runner(self):
        for name, document in workflow_documents().items():
            for job_name, job in document.get("jobs", {}).items():
                self.assertIn("runs-on", job, "%s:%s" % (name, job_name))
                timeout = job.get("timeout-minutes")
                self.assertIsInstance(timeout, int, "%s:%s" % (name, job_name))
                self.assertGreater(timeout, 0, "%s:%s" % (name, job_name))
                self.assertLessEqual(timeout, 90, "%s:%s" % (name, job_name))
                self.assertNotIn("latest", str(job["runs-on"]), "%s:%s" % (name, job_name))

    def test_actions_are_pinned_to_full_commit_shas_with_version_comments(self):
        for name, document in workflow_documents().items():
            for job_name, job in document.get("jobs", {}).items():
                for step in job.get("steps", []):
                    uses = step.get("uses")
                    if not uses:
                        continue
                    if uses.startswith("./"):
                        continue
                    if uses.startswith("docker://"):
                        self.assertRegex(uses, FULL_DOCKER_DIGEST, "%s:%s" % (name, job_name))
                        continue
                    self.assertRegex(uses, r"^[^@]+@[0-9a-f]{40}$",
                                     "%s:%s:%s" % (name, job_name, uses))
            for line in (WORKFLOWS / name).read_text(encoding="utf-8").splitlines():
                match = re.match(r"\s*(?:-\s*)?uses:\s*(\S+)", line)
                if match and not match.group(1).startswith(("./", "docker://")):
                    self.assertRegex(line, r"#\s*v?\d", line)

    def test_required_verification_has_no_escape_hatches(self):
        for name, document in workflow_documents().items():
            for job_name, job in document.get("jobs", {}).items():
                self.assertIsNot(job.get("continue-on-error"), True, "%s:%s" % (name, job_name))
                for step in job.get("steps", []):
                    self.assertIsNot(step.get("continue-on-error"), True,
                                     "%s:%s" % (name, job_name))
                    self.assertIsNot(step.get("if"), False, "%s:%s" % (name, job_name))
                    run = step.get("run", "")
                    if "scripts/verify-suite.py" not in run:
                        continue
                    for marker in ("|| true", "|| :", "set +e", "--allow-no-device"):
                        self.assertNotIn(marker, run, "%s:%s" % (name, job_name))

    def test_required_jobs_are_exactly_the_declared_lanes(self):
        document = workflow_documents()["ci.yml"]
        jobs = document.get("jobs", {})
        self.assertEqual(set(jobs), set(REQUIRED_JOBS) | {"verify-required"})

    def test_required_lanes_call_the_shared_verifier(self):
        document = workflow_documents()["ci.yml"]
        jobs = document["jobs"]
        for job_name, lane in REQUIRED_LANES.items():
            runs = step_runs(jobs[job_name])
            calls = [run for run in runs if "scripts/verify-suite.py" in run]
            self.assertEqual(len(calls), 1, job_name)
            self.assertIn("--only " + lane, calls[0], job_name)
            for run in runs:
                for forbidden in ("cargo test", "gradlew", "xcodebuild", "unittest", "pytest"):
                    self.assertNotIn(forbidden, run, "%s:%s" % (job_name, forbidden))

    def test_required_lanes_always_upload_evidence(self):
        document = workflow_documents()["ci.yml"]
        for job_name in REQUIRED_JOBS:
            uploads = [
                step for step in document["jobs"][job_name].get("steps", [])
                if step.get("uses", "").startswith("actions/upload-artifact@")
            ]
            self.assertEqual(len(uploads), 1, job_name)
            upload = uploads[0]
            self.assertEqual(upload.get("if"), "always()", job_name)
            with_ = upload.get("with", {})
            self.assertEqual(with_.get("if-no-files-found"), "error", job_name)
            self.assertIn("build/reports/verification", with_.get("path", ""), job_name)

    def test_required_aggregator_is_fail_closed_and_does_not_checkout(self):
        document = workflow_documents()["ci.yml"]
        aggregator = document["jobs"]["verify-required"]
        self.assertEqual(aggregator.get("if"), "always()")
        self.assertEqual(set(aggregator.get("needs", [])), set(REQUIRED_JOBS))
        self.assertEqual(aggregator.get("runs-on"), "ubuntu-24.04")
        self.assertEqual(aggregator.get("permissions"), {})
        steps = aggregator.get("steps", [])
        self.assertEqual(len(steps), 1)
        self.assertNotIn("uses", steps[0])
        self.assertIn("NEEDS_JSON", steps[0].get("env", {}))
        self.assertIn("EXPECTED_LANES", steps[0].get("env", {}))
        self.assertIn("python3 - <<'PY'", steps[0].get("run", ""))
        self.assertEqual(
            steps[0]["env"]["EXPECTED_LANES"].split(),
            list(REQUIRED_JOBS),
        )

    def test_required_aggregator_rejects_every_non_success_shape(self):
        document = workflow_documents()["ci.yml"]
        step = document["jobs"]["verify-required"]["steps"][0]
        expected = step["env"]["EXPECTED_LANES"].split()
        successful = {name: {"result": "success"} for name in expected}
        cases = [
            ("success", successful, 0),
            ("failure", {**successful, "verify-contracts": {"result": "failure"}}, 1),
            ("cancelled", {**successful, "verify-rust": {"result": "cancelled"}}, 1),
            ("skipped", {**successful, "verify-android": {"result": "skipped"}}, 1),
            ("neutral", {**successful, "verify-ci-integrity": {"result": "neutral"}}, 1),
            ("missing-result", {**successful, "verify-rust": {}}, 1),
            ("missing-lane", {name: {"result": "success"} for name in expected[:-1]}, 1),
            ("unexpected-lane", {**successful, "unexpected": {"result": "success"}}, 1),
            ("non-object-row", {**successful, "verify-rust": "success"}, 1),
            ("empty", {}, 1),
        ]
        for label, needs, expected_code in cases:
            with self.subTest(label=label):
                completed = subprocess.run(
                    ["bash", "-e", "-o", "pipefail", "-c", step["run"]],
                    cwd=ROOT,
                    env=os.environ | {
                        "NEEDS_JSON": json.dumps(needs),
                        "EXPECTED_LANES": " ".join(expected),
                    },
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(completed.returncode, expected_code, completed.stdout + completed.stderr)
                if expected_code:
                    self.assertIn("::error::", completed.stdout)
                else:
                    self.assertIn("All required lanes succeeded", completed.stdout)
        for label, environment in (
            ("malformed-json", {"NEEDS_JSON": "{", "EXPECTED_LANES": " ".join(expected)}),
            ("missing-needs", {"EXPECTED_LANES": " ".join(expected)}),
            ("empty-expected", {"NEEDS_JSON": "{}", "EXPECTED_LANES": ""}),
        ):
            with self.subTest(label=label):
                completed = subprocess.run(
                    ["bash", "-e", "-o", "pipefail", "-c", step["run"]],
                    cwd=ROOT,
                    env={**os.environ, **environment},
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)

    def test_workflow_declares_merge_queue_and_manual_dispatch(self):
        events = triggers(workflow_documents()["ci.yml"])
        self.assertIn("pull_request", events)
        self.assertIn("merge_group", events)
        self.assertIn("workflow_dispatch", events)

    def test_pull_request_workflows_never_download_or_run_pr_artifacts(self):
        for name, document in workflow_documents().items():
            if not (triggers(document) & PR_EVENTS):
                continue
            for job_name, job in document.get("jobs", {}).items():
                for step in job.get("steps", []):
                    uses = step.get("uses", "")
                    self.assertFalse(uses.startswith("actions/download-artifact@"),
                                     "%s:%s" % (name, job_name))
                    self.assertNotIn("workflow_run", uses, "%s:%s" % (name, job_name))

    def test_actionlint_download_is_versioned_and_checksummed(self):
        document = workflow_documents()["ci.yml"]
        steps = document["jobs"]["verify-ci-integrity"]["steps"]
        install = next(step for step in steps if step.get("name") == "Install pinned actionlint")
        run = install["run"]
        self.assertIn("v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz", run)
        self.assertRegex(run, r"[0-9a-f]{64}\s+build/tools/actionlint.tar.gz")

    def test_android_license_setup_handles_sigpipe_without_hiding_sdk_failures(self):
        document = workflow_documents()["ci.yml"]
        runs = step_runs(document["jobs"]["verify-android"])
        commands = [
            line.strip()
            for run in runs
            for line in run.splitlines()
            if "--licenses" in line and not line.lstrip().startswith("#")
        ]
        self.assertEqual(len(commands), 1)
        with tempfile.TemporaryDirectory(prefix="anice SDK setup ") as directory:
            root = Path(directory)
            sdk = root / "Android SDK"
            manager = sdk / "cmdline-tools/latest/bin/sdkmanager"
            manager.parent.mkdir(parents=True)
            manager.write_text("""#!/bin/sh
read -r answer
printf 'sdkmanager: %s; answer=%s\\n' "$*" "$answer"
exit "$ANICE_TEST_SDK_EXIT"
""")
            manager.chmod(0o755)
            reports = root / "build/reports/ci"
            reports.mkdir(parents=True)
            # The manager stops reading early, as the real tool does after accepting its answers.
            for exit_code in (0, 7):
                with self.subTest(exit_code=exit_code):
                    env = os.environ | {
                        "ANDROID_HOME": str(sdk),
                        "ANICE_TEST_SDK_EXIT": str(exit_code),
                    }
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c", commands[0]],
                        cwd=root, env=env, capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    log = (reports / "android-licenses.log").read_text()
                    self.assertIn("--sdk_root=" + str(sdk), log)
                    self.assertIn("answer=y", log)

    def test_macos_lane_pins_a_supported_image_and_full_xcode(self):
        job = workflow_documents()["ci.yml"]["jobs"]["verify-macos"]
        self.assertEqual(job.get("runs-on"), "macos-15")
        self.assertEqual(
            job.get("env", {}).get("DEVELOPER_DIR"),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )
        self.assertNotIn("macos-14", str(job))
        install = next(
            step for step in job["steps"]
            if step.get("name") == "Set up Rust and macOS targets"
        )
        self.assertIn("aarch64-apple-darwin", install["run"])
        self.assertNotIn("x86_64-apple-darwin", install["run"])
        keychain = next(
            step for step in job["steps"]
            if step.get("name") == "Prepare isolated test keychain"
        )
        self.assertIn("security create-keychain", keychain["run"])
        self.assertIn("security unlock-keychain", keychain["run"])
        verify = next(
            step for step in job["steps"] if step.get("name") == "Verify macOS app"
        )
        self.assertEqual(
            verify.get("run", "").strip(),
            "python3 scripts/verify-suite.py --only macos",
        )

    def test_runtime_workflow_pins_emulator_matrix_and_is_nightly_only(self):
        document = workflow_documents()["runtime.yml"]
        events = triggers(document)
        self.assertEqual(events, {"schedule", "workflow_dispatch"})
        self.assertEqual(document.get("permissions"), {"contents": "read"})
        job = document["jobs"]["verify-android-connected"]
        self.assertEqual(job.get("runs-on"), "ubuntu-24.04")
        matrix = job.get("strategy", {}).get("matrix", {}).get("include", [])
        self.assertEqual({row.get("api-level") for row in matrix}, {29, 36})
        runner_step = next(
            step for step in job["steps"]
            if "android-emulator-runner" in step.get("uses", "")
        )
        self.assertEqual(
            runner_step["uses"],
            "ReactiveCircus/android-emulator-runner@a421e43855164a8197daf9d8d40fe71c6996bb0d",
        )
        settings = runner_step.get("with", {})
        self.assertIs(settings.get("force-avd-creation"), True)
        self.assertIs(settings.get("disable-linux-hw-accel"), False)
        for option in ('-accel on', '-no-snapshot', '-wipe-data'):
            self.assertIn(option, settings.get('emulator-options', ''))
        self.assertEqual(settings.get('script'),
                         'python3 scripts/verify-suite.py --only connected --serial "$ANDROID_SERIAL"')
        self.assertIn('-accel-check', settings.get('pre-emulator-launch-script', ''))
        self.assertIn('pipefail', settings.get('pre-emulator-launch-script', ''))
        self.assertIn('avd-config.ini', settings.get('pre-emulator-launch-script', ''))
        kvm = next(step for step in job['steps'] if step.get('name') == 'Require KVM access')
        self.assertIn('! -c /dev/kvm', kvm['run'])
        self.assertIn('exit 1', kvm['run'])
        self.assertNotIn('|| true', kvm['run'])
        upload = next(
            step for step in job["steps"]
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        self.assertEqual(upload.get("if"), "always()")
        self.assertEqual(upload.get("with", {}).get("if-no-files-found"), "error")

    def test_emulator_acceleration_probe_keeps_failure_status_and_evidence(self):
        job = workflow_documents()['runtime.yml']['jobs']['verify-android-connected']
        settings = next(step['with'] for step in job['steps']
                        if 'android-emulator-runner' in step.get('uses', ''))
        command = settings['pre-emulator-launch-script'].splitlines()[0]
        with tempfile.TemporaryDirectory(prefix='anice emulator probe ') as directory:
            root = Path(directory)
            emulator = root / 'Android SDK/emulator/emulator'
            emulator.parent.mkdir(parents=True)
            emulator.write_text('#!/bin/sh\nprintf "acceleration status %s\\n" "$ACCEL_EXIT"\nexit "$ACCEL_EXIT"\n')
            emulator.chmod(0o755)
            (root / 'build/reports/emulator').mkdir(parents=True)
            for code in (0, 7):
                with self.subTest(exit_code=code):
                    result = subprocess.run(['sh', '-c', command], cwd=root,
                        env=os.environ | {'ANDROID_HOME': str(root / 'Android SDK'), 'ACCEL_EXIT': str(code)},
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertIn('acceleration status ' + str(code),
                                  (root / 'build/reports/emulator/acceleration.log').read_text())

    def test_device_lab_workflow_is_protected_and_self_hosted(self):
        document = workflow_documents()["device-lab.yml"]
        events = triggers(document)
        self.assertNotIn("pull_request", events)
        self.assertNotIn("merge_group", events)
        self.assertLessEqual(events, {"schedule", "workflow_dispatch", "push"})
        self.assertEqual(document.get("permissions"), {"contents": "read"})
        job = document["jobs"]["verify-native-interchange"]
        self.assertEqual(job.get("environment"), "device-lab")
        runner = job.get("runs-on")
        self.assertIn("self-hosted", runner)
        self.assertIn("device-lab", runner)
        runs = step_runs(job)
        self.assertTrue(any("scripts/check-device-health.py" in run for run in runs))
        self.assertTrue(any("scripts/verify-suite.py --only interchange" in run for run in runs))
        upload = next(
            step for step in job["steps"]
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        self.assertEqual(upload.get("if"), "always()")
        self.assertEqual(upload.get("with", {}).get("if-no-files-found"), "error")

    def test_device_lab_serial_is_environment_data_not_interpolated_shell_code(self):
        job = workflow_documents()['device-lab.yml']['jobs']['verify-native-interchange']
        self.assertEqual(job['env']['ANICE_DEVICE_SERIAL'], '${{ inputs.serial }}')
        steps = [step['run'] for step in job['steps']
                 if step.get('name') in ('Preflight device thermal and battery guardrails',
                                        'Verify native interchange')]
        with tempfile.TemporaryDirectory(prefix='anice lab serial ') as directory:
            root = Path(directory)
            bin_ = root / 'bin'
            bin_.mkdir()
            python = bin_ / 'python3'
            python.write_text(f'''#!/bin/sh
exec {shlex.quote(sys.executable)} - "$@" <<'PY'
import json, os, sys
with open(os.environ['CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
PY
''')
            python.chmod(0o755)
            log = root / 'calls.jsonl'
            for serial in ('', 'phone-1', 'phone with spaces', 'phone;$(touch injected)'):
                with self.subTest(serial=serial):
                    log.unlink(missing_ok=True)
                    env = os.environ | {'PATH': str(bin_) + os.pathsep + os.environ['PATH'],
                        'ANICE_DEVICE_SERIAL': serial, 'CALLS': str(log)}
                    for command in steps:
                        self.assertNotIn('${{', command)
                        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command],
                                                cwd=root, env=env, capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    commands = [json.loads(line) for line in log.read_text().splitlines()]
                    self.assertEqual(len(commands), 2)
                    for command in commands:
                        self.assertEqual(command[command.index('--serial') + 1], serial)
                    self.assertFalse((root / 'injected').exists())

    def test_mac_release_rejects_injected_or_changed_entitlements(self):
        script = (ROOT / 'scripts/build_release_macos.sh').read_text()
        self.assertIn('CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', script)
        code = script.split("<<'PYCODE'\n", 1)[1].split('\nPYCODE', 1)[0]
        import plistlib
        expected = plistlib.loads((ROOT / 'apps/macos/aniCe/aniCe.entitlements').read_bytes())
        with tempfile.TemporaryDirectory() as directory:
            source, signed = Path(directory) / 'source.plist', Path(directory) / 'signed.plist'
            source.write_bytes(plistlib.dumps(expected))
            cases = [expected, {**expected, 'com.apple.security.get-task-allow': True},
                     {**expected, 'com.apple.security.network.client': False}, {}]
            for index, actual in enumerate(cases):
                signed.write_bytes(plistlib.dumps(actual))
                result = subprocess.run([sys.executable, '-c', code, str(source), str(signed)],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0 if index == 0 else 1, result.stderr)
                if index:
                    self.assertIn('expected', result.stderr)
                    self.assertIn('signed', result.stderr)

    def test_mac_release_cleanup_continues_after_timeout_and_preserves_failure(self):
        from unittest.mock import patch
        script = (ROOT / 'scripts/build_release_macos.sh').read_text()
        code = script.split("<<'CLEANUP'", 1)[1].split('\n', 1)[1].split('\nCLEANUP', 1)[0]
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if len(calls) == 1:
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])
            if len(calls) == 2:
                raise subprocess.CalledProcessError(1, command)

        with patch.object(sys, 'argv', ['cleanup', '/tmp/isolated-signing', '/tmp/keychain']), \
                patch('subprocess.run', side_effect=run):
            with self.assertRaises(SystemExit) as raised:
                exec(compile(code, '<release-cleanup>', 'exec'), {})
        self.assertEqual(raised.exception.code, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][0][:2], ['sudo', '-n'])
        self.assertEqual([kwargs['timeout'] for _, kwargs in calls], [15, 15, 30])
        self.assertEqual(calls[-1][0], ['rm', '-rf', '/tmp/isolated-signing'])
        with patch.object(sys, 'argv', ['cleanup', '/tmp/isolated-signing', '/tmp/keychain']), \
                patch('subprocess.run', side_effect=OSError('injected cleanup failure')):
            with self.assertRaises(SystemExit) as raised:
                exec(compile(code, '<release-cleanup>', 'exec'), {})
        self.assertEqual(raised.exception.code, 1)
        cleanup = script[script.index('cleanup() {'):script.index('trap cleanup EXIT')]
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'python3'
            executable.write_text('#!/bin/sh\nexit 1\n')
            executable.chmod(0o755)
            for original, expected in ((0, 1), (7, 7)):
                result = subprocess.run(['/bin/bash', '-c', cleanup + '\ntrap cleanup EXIT\nexit ' + str(original)],
                                        env={**os.environ, 'PATH': directory}, timeout=5)
                self.assertEqual(result.returncode, expected)

    def test_release_source_selection_rejects_mismatched_tag_before_ci_or_builds(self):
        step = next(s for s in workflow_documents()['release.yml']['jobs']['metadata']['steps']
                    if s.get('id') == 'version')
        source_check = step['run'].split('PYTHONPATH=scripts', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            git = Path(directory) / 'git'
            git.write_text('#!/bin/sh\nif [ "$1" = rev-parse ]; then\n'
                           '  if [ "$2" = HEAD ]; then echo "$TEST_HEAD"; else echo "$TEST_TAG"; fi\nfi\n')
            git.chmod(0o755)
            for event, dry_run, head, tag, accepted in (
                    ('push', '', 'a' * 40, 'a' * 40, True),
                    ('push', '', 'a' * 40, 'b' * 40, False),
                    ('workflow_dispatch', 'false', 'a' * 40, 'b' * 40, False),
                    ('workflow_dispatch', 'false', 'a' * 40, 'a' * 40, True),
                    ('workflow_dispatch', 'true', 'a' * 40, 'b' * 40, True)):
                with self.subTest(event=event, dry_run=dry_run, tag=tag):
                    result = subprocess.run(['/bin/bash', '-c', source_check], cwd=ROOT,
                        env={**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH'],
                             'RELEASE_TAG': 'v0.9.0-beta.1', 'EVENT_NAME': event, 'DRY_RUN': dry_run,
                             'TEST_HEAD': head, 'TEST_TAG': tag, 'GITHUB_OUTPUT': directory + '/output'},
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_release_preflight_rejects_configuration_before_builds_without_device_gate(self):
        job = workflow_documents()['release.yml']['jobs']['metadata']
        self.assertEqual(job['environment'], 'release')
        step = next(s for s in job['steps'] if s.get('name', '').startswith('Check signing configuration'))
        self.assertNotIn('VERIFIED_COMMIT', step['env'])
        self.assertNotIn('VERIFIED_COMMIT', step['run'])
        values = {key: 'true' for key in step['env'] if key.startswith('HAS_')}
        values.update(MAC_SIGNING_IDENTITY='test signer', ANDROID_CERT_SHA256='a' * 64,
                      MAC_UPDATE_PIN_CURRENT='b' * 64, MAC_UPDATE_PIN_NEXT='',
                      RELEASE_COMMIT='c' * 40,
                      RELEASE_TAG='v0.9.0-beta.1', PREPARE_DRAFT='true')
        with tempfile.TemporaryDirectory() as directory:
            python = Path(directory) / 'python3'
            python.write_text('#!/bin/sh\ncat >/dev/null\nprintf checked > "$PREFLIGHT_MARKER"\n')
            python.chmod(0o755)
            marker_path = Path(directory) / 'checked'
            cases = [({}, True, True), ({'PREPARE_DRAFT': 'false'}, True, False),
                     ({'MAC_UPDATE_PIN_CURRENT': 'bad'}, False, False),
                     ({'ANDROID_CERT_SHA256': ''}, False, False),
                     ({'MAC_UPDATE_PIN_NEXT': 'bad'}, False, False),
                     ({'MAC_SIGNING_IDENTITY': ''}, False, False)]
            cases.extend(({name: 'false'}, False, False) for name in values if name.startswith('HAS_'))
            for changes, accepted, called in cases:
                with self.subTest(changes=changes):
                    marker_path.unlink(missing_ok=True)
                    result = subprocess.run(['/bin/bash', '-c', step['run']],
                        env={**os.environ, **values, **changes, 'PREFLIGHT_MARKER': str(marker_path),
                             'PATH': directory + os.pathsep + os.environ['PATH']},
                        capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    self.assertEqual(marker_path.exists(), called)

    def test_release_and_ci_share_arm64_toolchain_and_release_jobs_are_bounded(self):
        documents = workflow_documents()
        release = documents['release.yml']['jobs']
        self.assertEqual(set(release), {'metadata', 'android', 'macos', 'publish'})
        self.assertEqual(release['macos']['env']['DEVELOPER_DIR'],
                         documents['ci.yml']['jobs']['verify-macos']['env']['DEVELOPER_DIR'])
        setup = next(step for step in release['macos']['steps'] if step.get('name') == 'Install Rust targets')
        self.assertIn('aarch64-apple-darwin', setup['run'])
        self.assertNotIn('x86_64-apple-darwin', setup['run'])
        for job in release.values():
            self.assertIsInstance(job.get('timeout-minutes'), int)

    def test_release_checks_ci_before_signing_and_keeps_publication_manual(self):
        jobs = workflow_documents()['release.yml']['jobs']
        metadata = jobs['metadata']
        self.assertEqual(metadata['permissions'], {'contents': 'read', 'actions': 'read'})
        source_check = next(step for step in metadata['steps'] if step.get('id') == 'version')
        self.assertIn('git merge-base --is-ancestor "$commit" refs/remotes/origin/main', source_check['run'])
        self.assertIn("require_ci(os.environ['GITHUB_REPOSITORY'], sys.argv[1])", source_check['run'])
        for platform in ('android', 'macos'):
            self.assertEqual(jobs[platform]['needs'], 'metadata')
            self.assertEqual(jobs[platform]['environment'], 'release')
        draft = jobs['publish']
        self.assertEqual(set(draft['needs']), {'metadata', 'android', 'macos'})
        self.assertEqual(draft['permissions'], {'contents': 'write', 'actions': 'read'})
        names = [step.get('name') for step in draft['steps']]
        self.assertLess(names.index('Require device verification for this commit'),
                        names.index('Prepare and verify release draft'))
        self.assertNotIn('--draft=false', '\n'.join(step_runs(draft)))

    def test_release_device_gate_allows_only_the_tested_commit_at_publication(self):
        draft = workflow_documents()['release.yml']['jobs']['publish']
        gate = next(step for step in draft['steps'] if step.get('name') == 'Require device verification for this commit')
        for verified, accepted in (('a' * 40, True), ('', False), ('b' * 40, False), ('not-a-commit', False)):
            with self.subTest(verified=verified):
                result = subprocess.run(
                    ['bash', '-e', '-o', 'pipefail', '-c', gate['run']],
                    cwd=ROOT,
                    env=os.environ | {'VERIFIED_COMMIT': verified, 'RELEASE_COMMIT': 'a' * 40},
                    capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                if not accepted:
                    self.assertIn('rerun only this job', result.stderr)

    def test_security_workflow_policies(self):
        document = workflow_documents()["security.yml"]
        events = triggers(document)
        self.assertNotIn("pull_request", events)
        self.assertNotIn("pull_request_target", events)
        self.assertEqual(document.get("permissions"), {"contents": "read"})
        codeql = document["jobs"]["codeql"]
        self.assertEqual(codeql.get("permissions"), {"contents": "read", "security-events": "write"})
        self.assertIn("java-kotlin", codeql.get("strategy", {}).get("matrix", {}).get("language", []))
        codeql_swift = document["jobs"]["codeql-swift"]
        self.assertEqual(codeql_swift.get("runs-on"), "macos-15")
        self.assertIn("Xcode_26.3.app", codeql_swift.get("env", {}).get("DEVELOPER_DIR", ""))
        self.assertEqual(codeql_swift.get("permissions"), {"contents": "read", "security-events": "write"})
        self.assertEqual(set(document["jobs"]), {"codeql", "codeql-swift"})

    def test_compiled_codeql_languages_have_explicit_builds_before_analysis(self):
        jobs = workflow_documents()['security.yml']['jobs']
        kotlin = jobs['codeql']['steps']
        init = next(index for index, step in enumerate(kotlin) if step.get('name') == 'Initialize CodeQL')
        build = next(index for index, step in enumerate(kotlin) if step.get('name') == 'Build Android app for CodeQL')
        analyze = next(index for index, step in enumerate(kotlin) if step.get('name') == 'Perform CodeQL Analysis')
        self.assertLess(init, build)
        self.assertLess(build, analyze)
        self.assertIn("'manual'", kotlin[init]['with']['build-mode'])
        self.assertEqual(kotlin[build]['if'], "matrix.language == 'java-kotlin'")
        self.assertIn('assembleDebug', kotlin[build]['run'])
        self.assertIn('--no-build-cache', kotlin[build]['run'])
        swift = jobs['codeql-swift']['steps']
        setup = next(step for step in swift if step.get('name') == 'Set up Rust and macOS target')
        self.assertIn('aarch64-apple-darwin', setup['run'])
        self.assertNotIn('x86_64-apple-darwin', setup['run'])
        self.assertEqual(next(step['with']['build-mode'] for step in swift
                              if step.get('name') == 'Initialize CodeQL'), 'manual')

    def test_dependency_review_workflow_policies(self):
        document = workflow_documents()["dependency-review.yml"]
        events = triggers(document)
        self.assertEqual(events, {"pull_request"})
        self.assertEqual(document.get("permissions"), {"contents": "read"})
        job = document["jobs"]["dependency-review"]
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        step = next(s for s in job["steps"] if "dependency-review-action" in s.get("uses", ""))
        self.assertEqual(step.get("with", {}).get("fail-on-severity"), "high")

    def test_codeowners_covers_the_gate_files(self):
        path = ROOT / ".github" / "CODEOWNERS"
        patterns = [
            line.split()[0]
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        for required in (
            "/.github/workflows/",
            "/.github/actionlint.yaml",
            "/.github/PULL_REQUEST_TEMPLATE.md",
            "/SECURITY.md",
            "/CONTRIBUTING.md",
            "/scripts/verify-suite.py",
            "/scripts/test_ci_workflow.py",
            "/scripts/test_verify_suite.py",
            "/scripts/test_device_health.py",
            "/scripts/check-device-health.py",
            "/tools/device-lab/",
            "/scripts/build-pairing-native.py",
            "/scripts/test_pairing_build.py",
            "/scripts/build_release_macos.sh",
            "/scripts/publish_release.py",
            "/scripts/test_publish_release.py",
            "/scripts/release_version.py",
            "/scripts/test_release_version.py",
            "/apps/android/app/src/main/java/io/github/anisharyal09/anice/update/",
            "/apps/android/app/src/test/java/io/github/anisharyal09/anice/update/",
            "/apps/android/app/build.gradle.kts",
            "/apps/macos/aniCe/Update/",
            "/apps/macos/aniCeTests/MacUpdateSignatureTests.swift",
            "/scripts/requirements.txt",
        ):
            self.assertIn(required, patterns)


if __name__ == "__main__":
    unittest.main()
