#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare a verified release draft; publication remains a maintainer action."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

from release_version import parse_tag

MAX_BYTES = 256 * 1024 * 1024
NAMES = ("aniCe-android.apk", "aniCe-mac.zip")


def require_ci(repository, commit):
    """Only the latest main-push CI run for this exact source can authorize signing."""
    endpoint = f"repos/{repository}/actions/workflows/ci.yml/runs?head_sha={commit}&branch=main&event=push&per_page=100"
    response = json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))
    runs = [run for run in response.get("workflow_runs", [])
            if run.get("head_sha") == commit and run.get("head_branch") == "main"
            and run.get("event") == "push"]
    latest = max(runs, key=lambda run: run["id"], default=None)
    if not latest or latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("The latest main-push CI run for the release commit must succeed")


def gh(*args, **kwargs):
    return subprocess.run(["gh", *args], check=True, **kwargs)


def digest(path):
    sha = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def unexpected_assets(release):
    return sorted(str(item.get("name")) for item in release.get("assets", [])
                  if not isinstance(item, dict) or item.get("name") not in NAMES)


def apk_code(path, aapt):
    output = subprocess.check_output([aapt, "dump", "badging", str(path)], text=True)
    match = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", output, re.MULTILINE)
    if not match or match.group(1) != "io.github.anisharyal09.anice":
        raise ValueError("APK package metadata is invalid")
    return int(match.group(2)), match.group(3)


def main():
    tag, commit, directory = sys.argv[1:]
    version, code, prerelease = parse_tag(tag)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit")
    repository = os.environ["GITHUB_REPOSITORY"]
    if repository.lower() != "anisharyal09/anice":
        raise ValueError("Release drafts are restricted to the aniCe repository")
    def check_tag_commit():
        ref = json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/commits/{tag}"], text=True))
        if ref.get("sha") != commit:
            raise ValueError("Remote tag no longer identifies the built commit")
    check_tag_commit()
    require_ci(repository, commit)
    aapt = os.environ["ANICE_AAPT"]
    files = [pathlib.Path(directory) / name for name in NAMES]
    for path in files:
        if not path.is_file() or not 0 < path.stat().st_size <= MAX_BYTES:
            raise ValueError(f"Missing or oversized release asset: {path.name}")
    if apk_code(files[0], aapt) != (code, version):
        raise ValueError("Candidate APK does not match its tag")
    raw = subprocess.check_output(["gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"], text=True)
    releases = [release for page in json.loads(raw) for release in page]
    marker = f"<!-- anice-source:{commit} -->"
    existing = next((item for item in releases if item.get("tag_name") == tag), None)
    if existing and (not existing.get("draft") or marker not in (existing.get("body") or "") or bool(existing.get("prerelease")) != prerelease):
        raise ValueError("Release already exists or draft does not match this source commit")
    with tempfile.TemporaryDirectory(prefix="anice-release-check-") as temporary:
        temp = pathlib.Path(temporary)
        for release in releases:
            if release.get("draft"):
                continue
            for asset in release.get("assets", []):
                if asset.get("name") != NAMES[0]:
                    continue
                if not isinstance(asset.get("id"), int) or not 0 < asset.get("size", 0) <= MAX_BYTES:
                    raise ValueError("A previous APK asset cannot be verified")
                old = temp / "previous.apk"
                with old.open("wb") as output:
                    gh("api", "-H", "Accept: application/octet-stream", f"repos/{repository}/releases/assets/{asset['id']}", stdout=output)
                if old.stat().st_size != asset["size"] or apk_code(old, aapt)[0] >= code:
                    raise ValueError("Candidate Android versionCode is not greater than a published APK")
        if existing is None:
            args = ["release", "create", tag, "--repo", repository, "--verify-tag", "--draft", "--title", tag, "--notes", marker, "--generate-notes"]
            if prerelease:
                args.append("--prerelease")
            gh(*args)
        release = json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/releases/tags/{tag}"], text=True))
        if not release.get("draft") or release.get("tag_name") != tag or marker not in (release.get("body") or "") or bool(release.get("prerelease")) != prerelease:
            raise ValueError("Draft changed before assets could be verified")
        extra = unexpected_assets(release)
        if extra:
            raise ValueError("Draft contains unexpected assets: " + ", ".join(extra))
        assets = {item["name"]: item for item in release.get("assets", [])}
        verified = {}
        for path in files:
            asset = assets.get(path.name)
            if asset is None:
                gh("release", "upload", tag, str(path), "--repo", repository)
                release = json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/releases/tags/{tag}"], text=True))
                assets = {item["name"]: item for item in release.get("assets", [])}
                asset = assets.get(path.name)
            if not asset or not isinstance(asset.get("id"), int) or asset.get("size") != path.stat().st_size:
                raise ValueError(f"Draft asset mismatch: {path.name}")
            downloaded = temp / path.name
            with downloaded.open("wb") as output:
                gh("api", "-H", "Accept: application/octet-stream", f"repos/{repository}/releases/assets/{asset['id']}", stdout=output)
            if digest(downloaded) != digest(path):
                raise ValueError(f"Draft asset digest mismatch: {path.name}")
            verified[path.name] = (asset["id"], asset["size"])
        check_tag_commit()
        latest = json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/releases/tags/{tag}"], text=True))
        current_assets = {item.get("name"): (item.get("id"), item.get("size")) for item in latest.get("assets", [])}
        if not latest.get("draft") or latest.get("tag_name") != tag or marker not in (latest.get("body") or "") \
                or bool(latest.get("prerelease")) != prerelease or set(current_assets) != set(NAMES) \
                or any(current_assets.get(name) != item for name, item in verified.items()):
            raise ValueError("Draft changed before verification completed")
        print(f"Verified draft ready for review: https://github.com/{repository}/releases")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Release draft not verified: {error}", file=sys.stderr)
        sys.exit(1)
