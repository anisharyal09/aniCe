#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Select CI, CodeQL and dependency checks from the exact changed Git paths."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HEX_SHA = re.compile(r"[0-9a-f]{40}")
ZERO_SHA = "0" * 40
NATIVE_LANES = ("rust", "android", "macos")
CODEQL_MATRIX = ("python", "actions", "java-kotlin")
RUNTIME_WORKFLOW = ".github/workflows/runtime.yml"
NATIVE_BRIDGE_SCRIPT = "scripts/build-pairing-native.py"

# These files are bundled by the native builds. Their contents are not code.
PACKAGED_NOTICES = {
    "LICENSE": ("macos",),
    "apps/macos/aniCe/Features/NowPlaying/Adapter/THIRD_PARTY_NOTICES.md": ("macos",),
    "core/rust/pairing/THIRD_PARTY_NOTICES.md": ("android", "macos"),
}
DOCUMENTATION_FILES = {
    ".gitignore",
    ".github/PULL_REQUEST_TEMPLATE.md",
    "apps/android/CHANGELOG.md",
    "apps/android/README.md",
    "apps/macos/CHANGELOG.md",
    "apps/macos/README.md",
    "core/rust/pairing/README.md",
}
GLOBAL_GATE_FILES = {
    ".gitattributes",
    ".github/CODEOWNERS",
    ".github/actionlint.yaml",
    "scripts/ci_changes.py",
    "scripts/verify-suite.py",
}

CONTRACT_ONLY_FILES = {
    ".github/dependabot.yaml",
    ".github/dependabot.yml",
    ".github/workflows/dependency-review.yml",
    ".github/workflows/device-lab.yml",
    ".github/workflows/release.yml",
    ".github/workflows/security.yml",
    RUNTIME_WORKFLOW,
    "scripts/check-device-health.py",
    "scripts/check-structure.py",
    "scripts/dev.sh",
    "scripts/publish_release.py",
    "scripts/release_version.py",
    "scripts/requirements.txt",
    "scripts/verify-identity-interchange.py",
    "scripts/verify-lan-interchange.py",
    "scripts/verify-session-interchange.py",
    "tools/device-lab/inventory.json",
}
WORKFLOW_PATHS = (".github/workflows/", ".github/actions/")
MANIFEST_NAMES = {
    "Cargo.lock", "Cargo.toml", "Package.resolved", "Package.swift", "Pipfile",
    "Pipfile.lock", "build.gradle", "build.gradle.kts", "gradle.lockfile",
    "gradle.properties", "gradle-wrapper.jar", "gradle-wrapper.properties",
    "poetry.lock", "project.pbxproj", "pyproject.toml", "settings.gradle",
    "settings.gradle.kts", "uv.lock",
}


def is_documentation(path):
    if path in DOCUMENTATION_FILES or ("/" not in path and path.endswith(".md")):
        return True
    if path.startswith(".github/ISSUE_TEMPLATE/"):
        return path.endswith((".md", ".yaml", ".yml"))
    if path.startswith("docs/"):
        return path.endswith((".md", ".png", ".svg", ".jpg", ".webp"))
    if not path.endswith(".md"):
        return False
    if path.startswith(("protocol/fixtures/", "protocol/test-vectors/")):
        return False  # Native tests can package everything under their fixture paths.
    return path.startswith((".agents/", "assets/logo/", "protocol/", "tools/"))


def is_contract_only(path):
    return (
        path in CONTRACT_ONLY_FILES
        or (path.startswith("scripts/test_") and path.endswith(".py"))
        or path.startswith("assets/logo/")
        # The independent oracles are checked against the committed native fixtures.
        or (path.startswith("protocol/test-vectors/") and path.endswith((".py", "/requirements.txt")))
    )


def ci_lanes_for_path(path):
    if path in PACKAGED_NOTICES:
        return PACKAGED_NOTICES[path]
    if path in GLOBAL_GATE_FILES or path == NATIVE_BRIDGE_SCRIPT:
        return NATIVE_LANES
    if is_documentation(path) or is_contract_only(path):
        return ()
    if path.startswith("apps/android/"):
        return ("android",)
    if path.startswith("apps/macos/") or path == "scripts/build_release_macos.sh":
        return ("macos",)
    if path.startswith("protocol/"):
        return ("android", "macos")
    # Includes the shared Rust bridge, the CI workflow and unknown build inputs.
    return NATIVE_LANES


def classify_ci_paths(paths):
    lanes = NATIVE_LANES if paths is None else {lane for path in paths for lane in ci_lanes_for_path(path)}
    return {f"run_{lane}": lane in lanes for lane in NATIVE_LANES}


def codeql_languages_for_path(path):
    if path in PACKAGED_NOTICES or is_documentation(path):
        return ()
    if path in (".github/workflows/security.yml", "scripts/ci_changes.py", ".gitattributes"):
        return (*CODEQL_MATRIX, "swift")

    languages = set()
    if path.endswith((".py", "/requirements.txt")):
        languages.add("python")
    if path.startswith(WORKFLOW_PATHS) or path in (".github/actionlint.yaml", ".github/CODEOWNERS"):
        languages.add("actions")
    elif path.startswith("core/rust/pairing/") or path == NATIVE_BRIDGE_SCRIPT:
        languages.update(("java-kotlin", "swift"))
    elif path.startswith("apps/android/"):
        languages.add("java-kotlin")
    elif path.startswith("apps/macos/") or path == "scripts/build_release_macos.sh":
        languages.add("swift")
    elif not (languages or path.startswith("protocol/") or is_contract_only(path)):
        return (*CODEQL_MATRIX, "swift")
    return languages


def classify_codeql_paths(paths):
    languages = (*CODEQL_MATRIX, "swift") if paths is None else {
        language for path in paths for language in codeql_languages_for_path(path)
    }
    matrix = [language for language in CODEQL_MATRIX if language in languages]
    return {
        "run_codeql": bool(matrix),
        "codeql_languages": matrix,
        "run_swift": "swift" in languages,
    }


def is_dependency_input(path):
    name = path.rsplit("/", 1)[-1]
    return (
        path.startswith(WORKFLOW_PATHS + (".github/dependency-review", "apps/android/gradle/"))
        or path in (".github/dependabot.yml", ".github/dependabot.yaml", "scripts/ci_changes.py")
        or name in MANIFEST_NAMES
        or name.endswith((".versions.toml", ".xcconfig"))
        or (name.startswith("requirements") and name.endswith(".txt"))
    )


def _run_git(args, repo_root):
    return subprocess.run(
        ["git", *args],
        cwd=repo_root,
        capture_output=True,
        check=False,
        timeout=45,
    )


def _valid_sha(sha):
    return isinstance(sha, str) and HEX_SHA.fullmatch(sha) is not None and sha != ZERO_SHA


def _workflow_runs(repository, workflow, query):
    endpoint = f"repos/{repository}/actions/workflows/{workflow}/runs?{query}"
    response = json.loads(subprocess.check_output(["gh", "api", endpoint], text=True, timeout=20))
    runs = response.get("workflow_runs") if isinstance(response, dict) else None
    if not isinstance(runs, list) or any(not isinstance(run, dict) or type(run.get("id")) is not int for run in runs):
        raise ValueError(f"Invalid GitHub Actions response for {workflow}")
    return runs


def main_push_ci_succeeded(repository, commit):
    """Look up the latest main-push CI result for exactly this commit."""
    if not _valid_sha(commit):
        return False
    query = f"head_sha={commit}&branch=main&event=push&per_page=100"
    runs = [
        run for run in _workflow_runs(repository, "ci.yml", query)
        if run.get("head_sha") == commit and run.get("head_branch") == "main" and run.get("event") == "push"
    ]
    latest = max(runs, key=lambda run: run["id"], default=None)
    return bool(latest and latest.get("status") == "completed" and latest.get("conclusion") == "success")


def previous_runtime_commit(repository, run_id):
    """Return the tested tree, or a tree that inherited its connected-test evidence."""
    runs = _workflow_runs(repository, "runtime.yml", "branch=main&event=schedule&per_page=10")
    earlier = (
        run for run in runs
        if run["id"] < run_id and run.get("head_branch") == "main" and run.get("event") == "schedule"
    )
    latest = max(earlier, key=lambda run: run["id"], default=None)
    if latest and latest.get("status") == "completed" and latest.get("conclusion") == "success":
        return latest.get("head_sha") or ""
    return ""


def _diff_commits(base_rev, head_rev, repo_root):
    # Report both ends of a rename: moving a source file out of a lane still changes that lane.
    result = _run_git(["diff", "--no-renames", "--name-only", "-z", base_rev, head_rev, "--"], repo_root)
    if result.returncode != 0:
        return None
    return [os.fsdecode(entry) for entry in result.stdout.split(b"\0") if entry]


def _pr_base(head, repo_root):
    # Inspect the merge header; only the first parent's tree is needed.
    commit = _run_git(["cat-file", "commit", head], repo_root)
    if commit.returncode != 0:
        return None
    headers = commit.stdout.split(b"\n\n", 1)[0].splitlines()
    parents = [line.removeprefix(b"parent ") for line in headers if line.startswith(b"parent ")]
    if len(parents) == 2:
        base = parents[0].decode("ascii", errors="replace")
        if _valid_sha(base):
            return base
    return None


def changed_paths_for_event(event, base="", head="HEAD", repo_root=ROOT):
    """Return None when the event or available history cannot justify skipping."""
    if head != "HEAD" and not _valid_sha(head):
        return None

    try:
        if event == "pull_request":
            # Compare the tested synthetic merge to its first parent, the base actually used.
            pr_base = _pr_base(head, repo_root)
            return _diff_commits(pr_base, head, repo_root) if pr_base else None
        if event in ("push", "merge_group") and _valid_sha(base):
            if _run_git(["cat-file", "-e", f"{base}^{{commit}}"], repo_root).returncode != 0:
                fetched = _run_git(["fetch", "--no-tags", "--depth=1", "origin", base], repo_root)
                if fetched.returncode != 0:
                    return None
            return _diff_commits(base, head, repo_root)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return None


def _write_github_output(values):
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={json.dumps(value)}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("ci", "codeql", "dependencies", "runtime"), required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)

    repository = os.environ.get("GITHUB_REPOSITORY")
    event = args.event
    base = args.base
    if args.mode == "runtime":
        event = "workflow_dispatch"
        base = ""
        if args.event == "schedule" and repository and os.environ.get("REUSE_SCHEDULED_RUNTIME") == "true":
            try:
                base = previous_runtime_commit(repository, int(os.environ["GITHUB_RUN_ID"]))
            except (KeyError, OSError, subprocess.SubprocessError, ValueError):
                base = ""
            event = "push"  # Compare the last verified and current trees directly.
    elif args.mode == "ci" and event == "push" and repository:
        # A newer push may have cancelled the previous CI run. Reuse native evidence
        # only when the predecessor actually passed, including on docs-only pushes.
        try:
            base_verified = main_push_ci_succeeded(repository, base)
        except (OSError, subprocess.SubprocessError, ValueError):
            base_verified = False
        if not base_verified:
            print("Previous main push has no verified CI result; running all native lanes.")
            base = ""

    paths = changed_paths_for_event(event, base=base, head=args.head)
    if args.mode == "runtime":
        runtime_changed = paths is not None and RUNTIME_WORKFLOW in paths
        decision = {"run_connected": runtime_changed or classify_ci_paths(paths)["run_android"]}
    elif args.mode == "ci":
        decision = classify_ci_paths(paths)
    elif args.mode == "codeql":
        decision = classify_codeql_paths(paths)
    elif args.mode == "dependencies":
        decision = {"review_dependencies": paths is None or any(map(is_dependency_input, paths))}

    _write_github_output(decision)
    print(json.dumps({"event": args.event, "changed_count": None if paths is None else len(paths), **decision}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
