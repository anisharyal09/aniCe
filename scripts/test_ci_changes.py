#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for selective CI and CodeQL change classification."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ci_changes", Path(__file__).with_name("ci_changes.py"))
ci_changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_changes)


class ChangeClassificationTests(unittest.TestCase):
    def test_docs_only_edits_skip_heavy_platform_lanes_and_codeql(self):
        doc_sets = [
            ["README.md"],
            ["DOCS.md", "docs/design/architecture.md", "apps/android/README.md", "apps/macos/README.md"],
            ["protocol/README.md", "protocol/bluetooth/COMPANION_SETUP.md", ".github/ISSUE_TEMPLATE/bug.yml"],
            [".gitignore", ".github/PULL_REQUEST_TEMPLATE.md", ".agents/RULES.md", "docs/design/preview.svg"],
        ]
        for paths in doc_sets:
            with self.subTest(paths=paths):
                decision = ci_changes.classify_ci_paths(paths)
                self.assertFalse(decision["run_rust"], paths)
                self.assertFalse(decision["run_android"], paths)
                self.assertFalse(decision["run_macos"], paths)

                ql = ci_changes.classify_codeql_paths(paths)
                self.assertFalse(ql["run_codeql"], paths)
                self.assertEqual(ql["codeql_languages"], [], paths)
                self.assertFalse(ql["run_swift"], paths)

    def test_packaged_notices_run_their_native_builds_without_codeql(self):
        cases = {
            "LICENSE": {"macos"},
            "apps/macos/aniCe/Features/NowPlaying/Adapter/THIRD_PARTY_NOTICES.md": {"macos"},
            "core/rust/pairing/THIRD_PARTY_NOTICES.md": {"android", "macos"},
        }
        for path, platforms in cases.items():
            with self.subTest(path=path):
                flags = ci_changes.classify_ci_paths([path])
                self.assertEqual(flags, {f"run_{lane}": lane in platforms for lane in ci_changes.NATIVE_LANES})
                ql = ci_changes.classify_codeql_paths([path])
                self.assertFalse(ql["run_codeql"])
                self.assertFalse(ql["run_swift"])

    def test_markdown_under_app_sources_and_fixtures_can_be_a_build_input(self):
        android = ci_changes.classify_ci_paths(["apps/android/app/src/main/assets/help.md"])
        self.assertEqual(android, {"run_rust": False, "run_android": True, "run_macos": False})
        shared = ci_changes.classify_ci_paths(["protocol/test-vectors/new-fixture.md"])
        self.assertEqual(shared, {"run_rust": False, "run_android": True, "run_macos": True})

    def test_android_only_changes_run_only_android_and_java_kotlin_codeql(self):
        decision = ci_changes.classify_ci_paths([
            "apps/android/app/src/main/java/io/github/anisharyal09/anice/MainActivity.kt",
            "README.md",
        ])
        self.assertFalse(decision["run_rust"])
        self.assertTrue(decision["run_android"])
        self.assertFalse(decision["run_macos"])

        ql = ci_changes.classify_codeql_paths([
            "apps/android/app/src/main/java/io/github/anisharyal09/anice/MainActivity.kt",
        ])
        self.assertTrue(ql["run_codeql"])
        self.assertEqual(ql["codeql_languages"], ["java-kotlin"])
        self.assertFalse(ql["run_swift"])

    def test_macos_only_changes_run_only_macos_and_swift_codeql(self):
        decision = ci_changes.classify_ci_paths([
            "apps/macos/aniCe/App/AniCeApp.swift",
            "docs/macos-notes.md",
        ])
        self.assertFalse(decision["run_rust"])
        self.assertFalse(decision["run_android"])
        self.assertTrue(decision["run_macos"])

        ql = ci_changes.classify_codeql_paths([
            "apps/macos/aniCe/App/AniCeApp.swift",
        ])
        self.assertFalse(ql["run_codeql"])
        self.assertEqual(ql["codeql_languages"], [])
        self.assertTrue(ql["run_swift"])

    def test_rust_and_bridge_changes_trigger_all_compiled_platforms(self):
        for path in ("core/rust/pairing/src/lib.rs", "scripts/build-pairing-native.py"):
            with self.subTest(path=path):
                decision = ci_changes.classify_ci_paths([path])
                self.assertTrue(decision["run_rust"])
                self.assertTrue(decision["run_android"])
                self.assertTrue(decision["run_macos"])

                ql = ci_changes.classify_codeql_paths([path])
                self.assertIn("java-kotlin", ql["codeql_languages"])
                self.assertTrue(ql["run_swift"])

    def test_protocol_changes_trigger_android_and_macos_without_rebuilding_rust(self):
        paths = ["protocol/session/session.cddl", "protocol/test-vectors/session/record-vectors.json"]
        self.assertEqual(ci_changes.classify_ci_paths(paths), {
            "run_rust": False, "run_android": True, "run_macos": True,
        })
        self.assertFalse(ci_changes.classify_codeql_paths(paths)["run_codeql"])

    def test_host_tool_or_oracle_only_changes_use_the_contracts_lane(self):
        paths = [
            "scripts/requirements.txt",
            "scripts/check-structure.py",
            "scripts/test_ci_changes.py",
            "scripts/test_ci_workflow.py",
            "scripts/test_pairing_build.py",
            "protocol/test-vectors/session/requirements.txt",
            "protocol/test-vectors/session/generate_session_vectors.py",
            "assets/logo/export-brand-icons.py",
        ]
        self.assertFalse(any(ci_changes.classify_ci_paths(paths).values()))
        self.assertEqual(ci_changes.classify_codeql_paths(paths)["codeql_languages"], ["python"])

    def test_standalone_workflows_do_not_trigger_unrelated_ci_native_builds(self):
        for workflow in ("dependency-review", "device-lab", "release", "runtime", "security"):
            with self.subTest(workflow=workflow):
                path = f".github/workflows/{workflow}.yml"
                self.assertFalse(any(ci_changes.classify_ci_paths([path]).values()))
                self.assertTrue(ci_changes.is_dependency_input(path))

    def test_different_platform_changes_are_combined(self):
        paths = ["apps/macos/new.swift", "apps/android/new.kt", "README.md"]
        self.assertEqual(ci_changes.classify_ci_paths(paths), {
            "run_rust": False, "run_android": True, "run_macos": True,
        })
        self.assertEqual(ci_changes.classify_codeql_paths(paths), {
            "run_codeql": True, "codeql_languages": ["java-kotlin"], "run_swift": True,
        })

    def test_workflow_verifier_and_unscoped_paths_fail_closed_to_full_run(self):
        for path in (
            ".github/workflows/ci.yml",
            ".github/actions/native/action.yml",
            ".github/CODEOWNERS",
            ".gitattributes",
            "scripts/verify-suite.py",
            "scripts/ci_changes.py",
            "scripts/new-build-helper.sh",
            "new-top-level-config.toml",
        ):
            with self.subTest(path=path):
                decision = ci_changes.classify_ci_paths([path, "README.md"])
                self.assertTrue(decision["run_rust"])
                self.assertTrue(decision["run_android"])
                self.assertTrue(decision["run_macos"])

    def test_none_paths_enable_everything(self):
        decision = ci_changes.classify_ci_paths(None)
        self.assertTrue(decision["run_rust"])
        self.assertTrue(decision["run_android"])
        self.assertTrue(decision["run_macos"])

        ql = ci_changes.classify_codeql_paths(None)
        self.assertTrue(ql["run_codeql"])
        self.assertEqual(ql["codeql_languages"], list(ci_changes.CODEQL_MATRIX))
        self.assertTrue(ql["run_swift"])

    def test_codeql_runs_every_language_when_its_selection_changes_or_scope_is_unknown(self):
        for path in (".github/workflows/security.yml", "scripts/ci_changes.py", "new-shared-config.toml"):
            with self.subTest(path=path):
                self.assertEqual(ci_changes.classify_codeql_paths([path]), ci_changes.classify_codeql_paths(None))

    def test_python_and_workflow_changes_select_matching_codeql_languages(self):
        ql = ci_changes.classify_codeql_paths([
            ".github/workflows/ci.yml",
            "scripts/verify-suite.py",
        ])
        self.assertTrue(ql["run_codeql"])
        self.assertEqual(ql["codeql_languages"], ["python", "actions"])
        self.assertFalse(ql["run_swift"])

    def test_dependency_review_includes_manifests_wrappers_and_action_changes(self):
        paths = [
            "apps/android/app/build.gradle.kts",
            "apps/android/gradle/wrapper/gradle-wrapper.jar",
            "apps/macos/aniCe.xcodeproj/project.pbxproj",
            "apps/macos/Package.swift",
            "core/rust/pairing/Cargo.lock",
            "protocol/test-vectors/session/requirements.txt",
            ".github/workflows/ci.yml",
            ".github/actions/native/action.yml",
            "scripts/ci_changes.py",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(ci_changes.is_dependency_input(path))
        for path in ("README.md", "docs/design/architecture.md", "apps/android/app/src/main/Foo.kt", "scripts/run.py"):
            with self.subTest(path=path):
                self.assertFalse(ci_changes.is_dependency_input(path))

    def test_git_diff_resolution_handles_zero_base_and_real_commits(self):
        self.assertIsNone(ci_changes.changed_paths_for_event("workflow_dispatch"))
        self.assertIsNone(ci_changes.changed_paths_for_event("schedule"))
        self.assertIsNone(ci_changes.changed_paths_for_event("push", base=ci_changes.ZERO_SHA))
        self.assertIsNone(ci_changes.changed_paths_for_event("push", base="not-a-sha"))

        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)

            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)

            git("init", "-b", "main")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.com")
            (repo / "README.md").write_text("hello\n")
            android = repo / "apps/android"
            android.mkdir(parents=True)
            (android / "Config.kt").write_text("// moved by the test\n")
            git("add", ".")
            git("commit", "-m", "init")
            base_sha = git("rev-parse", "HEAD").stdout.strip()

            (repo / "README.md").write_text("hello world\n")
            (repo / "docs").mkdir()
            (repo / "docs" / "guide with spaces.md").write_text("guide\n")
            git("add", ".")
            git("commit", "-m", "docs")
            main_sha = git("rev-parse", "HEAD").stdout.strip()

            paths = ci_changes.changed_paths_for_event("push", base=base_sha, head=main_sha, repo_root=repo)
            self.assertEqual(set(paths), {"README.md", "docs/guide with spaces.md"})
            self.assertFalse(any(ci_changes.classify_ci_paths(paths).values()))
            self.assertIsNone(ci_changes.changed_paths_for_event("push", base=base_sha, head="bad", repo_root=repo))

            # Neither unrelated updates on main nor checkout depth should hide the renamed source.
            git("checkout", "-b", "pr-branch", base_sha)
            (repo / "apps/macos").mkdir()
            git("mv", "apps/android/Config.kt", "apps/macos/Config.kt")
            git("commit", "-m", "pr rename")
            git("checkout", "main")
            git("merge", "--no-ff", "-m", "merge pr", "pr-branch")
            merge_sha = git("rev-parse", "HEAD").stdout.strip()
            shallow = repo / "shallow"
            git("clone", "--depth", "2", repo.as_uri(), str(shallow))
            expected = {"apps/android/Config.kt", "apps/macos/Config.kt"}

            pr_paths = ci_changes.changed_paths_for_event("pull_request", head=merge_sha, repo_root=shallow)
            self.assertEqual(set(pr_paths), expected)
            merge_paths = ci_changes.changed_paths_for_event("merge_group", base=main_sha, head=merge_sha, repo_root=shallow)
            self.assertEqual(set(merge_paths), expected)
            no_merge = ci_changes.changed_paths_for_event("pull_request", base=base_sha, head=main_sha, repo_root=shallow)
            self.assertIsNone(no_merge)

            # Multi-commit pushes may need to fetch a base outside the shallow history.
            self.assertEqual(git("-C", str(shallow), "rev-parse", "--is-shallow-repository").stdout.strip(), "true")
            push_paths = ci_changes.changed_paths_for_event("push", base=base_sha, head=merge_sha, repo_root=shallow)
            self.assertEqual(set(push_paths), expected | set(paths))

    def test_github_pr_can_diff_when_only_the_first_merge_parent_is_available(self):
        parent = b"parent " + b"a" * 40 + b"\n"
        second_parent = b"parent " + b"b" * 40 + b"\n"
        doc_diff = subprocess.CompletedProcess(["git"], 0, stdout=b"README.md\0")
        for parents, expected in ((parent + second_parent, ["README.md"]), (parent, None)):
            with self.subTest(parents=parents), patch.object(ci_changes, "_run_git", side_effect=[
                     subprocess.CompletedProcess(["git"], 0, stdout=parents + b"\na merge\n"),
                     doc_diff,
                 ]) as git:
                self.assertEqual(ci_changes.changed_paths_for_event("pull_request"), expected)
                if expected is not None:
                    self.assertIn("a" * 40, git.call_args.args[0])

    def test_git_errors_select_full_verification(self):
        for error in (OSError("git unavailable"), subprocess.TimeoutExpired("git", 45)):
            with self.subTest(error=error), patch.object(ci_changes, "_run_git", side_effect=error):
                self.assertIsNone(ci_changes.changed_paths_for_event("pull_request"))
                self.assertIsNone(ci_changes.changed_paths_for_event("push", base="a" * 40))

    def test_main_push_cannot_skip_native_checks_without_success_at_the_base(self):
        for verified in (True, False, subprocess.CalledProcessError(1, "gh")):
            with self.subTest(verified=verified), \
                 patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_OUTPUT": ""}), \
                 patch.object(ci_changes, "main_push_ci_succeeded") as previous, \
                 patch.object(ci_changes, "changed_paths_for_event") as changed, \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                if isinstance(verified, Exception):
                    previous.side_effect = verified
                else:
                    previous.return_value = verified
                changed.side_effect = lambda event, base, head: ["README.md"] if base else None
                ci_changes.main(["--mode", "ci", "--event", "push", "--base", "a" * 40])

                previous.assert_called_once_with("owner/repo", "a" * 40)
                flags = json.loads(output.getvalue().splitlines()[-1])
                self.assertEqual(flags["run_android"], verified is not True)
                self.assertEqual(flags["run_macos"], verified is not True)
                self.assertEqual(flags["run_rust"], verified is not True)

    def test_runtime_uses_only_the_latest_earlier_successful_schedule(self):
        verified = {"id": 2, "head_sha": "b" * 40, "head_branch": "main", "event": "schedule",
                    "status": "completed", "conclusion": "success"}
        current = {**verified, "id": 4}
        manual = {**verified, "id": 3, "event": "workflow_dispatch"}
        cases = (
            ([current, manual, verified], "b" * 40),
            ([current, {**verified, "id": 3, "conclusion": "failure"}, verified], ""),
            ([current, {**verified, "id": 3, "status": "in_progress"}, verified], ""),
            ([current, manual], ""),
        )
        for runs, expected in cases:
            with self.subTest(runs=runs), patch.object(
                ci_changes.subprocess, "check_output", return_value=json.dumps({"workflow_runs": runs})
            ):
                self.assertEqual(ci_changes.previous_runtime_commit("owner/repo", 4), expected)

    def test_runtime_skips_only_for_a_safe_unaffected_nightly(self):
        for event, reuse, paths, run_connected in (
            ("schedule", "true", ["README.md"], False),
            ("schedule", "true", ["apps/macos/new.swift"], False),
            ("schedule", "true", ["apps/android/new.kt"], True),
            ("schedule", "true", ["core/rust/pairing/Cargo.lock"], True),
            ("schedule", "true", [".github/workflows/runtime.yml"], True),
            ("schedule", "true", None, True),
            ("schedule", "false", None, True),
            ("workflow_dispatch", "true", None, True),
        ):
            with self.subTest(event=event, reuse=reuse, paths=paths), patch.dict(os.environ, {
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_RUN_ID": "2",
                "REUSE_SCHEDULED_RUNTIME": reuse,
                "GITHUB_OUTPUT": "",
            }), patch.object(ci_changes, "changed_paths_for_event", return_value=paths) as changed, \
                 patch.object(ci_changes, "previous_runtime_commit", return_value="a" * 40) as previous, \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                ci_changes.main(["--mode", "runtime", "--event", event])
                if event == "schedule" and reuse == "true":
                    previous.assert_called_once_with("owner/repo", 2)
                    changed.assert_called_once_with("push", base="a" * 40, head="HEAD")
                else:
                    previous.assert_not_called()
                    changed.assert_called_once_with("workflow_dispatch", base="", head="HEAD")
                self.assertEqual(json.loads(output.getvalue())["run_connected"], run_connected)

    def test_main_writes_github_output_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "github_output.txt"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}), \
                 patch.object(ci_changes, "changed_paths_for_event", return_value=["README.md"]), \
                 patch("sys.stdout", new_callable=io.StringIO):
                code = ci_changes.main(["--mode", "ci", "--event", "pull_request"])
            self.assertEqual(code, 0)
            written = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(written["run_rust"], "false")
            self.assertEqual(written["run_android"], "false")
            self.assertEqual(written["run_macos"], "false")

            out.unlink()
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}), \
                 patch.object(ci_changes, "changed_paths_for_event", return_value=["scripts/verify-suite.py"]), \
                 patch("sys.stdout", new_callable=io.StringIO):
                code = ci_changes.main(["--mode", "codeql", "--event", "push", "--base", "a" * 40])
            self.assertEqual(code, 0)
            written = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(written["run_codeql"], "true")
            self.assertEqual(json.loads(written["codeql_languages"]), ["python"])
            self.assertEqual(written["run_swift"], "false")

    def test_dependency_review_only_skips_on_a_known_non_dependency_diff(self):
        for paths, expected in ((None, "true"), (["README.md"], "false"), (["core/rust/pairing/Cargo.lock"], "true")):
            with self.subTest(paths=paths), tempfile.TemporaryDirectory() as directory:
                out = Path(directory) / "github_output.txt"
                with patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}), \
                     patch.object(ci_changes, "changed_paths_for_event", return_value=paths), \
                     patch("sys.stdout", new_callable=io.StringIO):
                    ci_changes.main(["--mode", "dependencies", "--event", "pull_request"])
                self.assertEqual(out.read_text(), f"review_dependencies={expected}\n")


if __name__ == "__main__":
    unittest.main()
