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
import subprocess
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

    def test_codeowners_covers_the_gate_files(self):
        path = ROOT / ".github" / "CODEOWNERS"
        patterns = [
            line.split()[0]
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        for required in (
            "/.github/workflows/",
            "/scripts/verify-suite.py",
            "/scripts/test_ci_workflow.py",
            "/scripts/test_verify_suite.py",
            "/scripts/build-pairing-native.py",
            "/scripts/requirements.txt",
        ):
            self.assertIn(required, patterns)


if __name__ == "__main__":
    unittest.main()
