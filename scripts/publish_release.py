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
    return sorted(str(item.get("name")) if isinstance(item, dict) else repr(item) for item in release.get("assets", [])
                  if not isinstance(item, dict) or item.get("name") not in NAMES)


def apk_code(path, aapt):
    output = subprocess.check_output([aapt, "dump", "badging", str(path)], text=True)
    match = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", output, re.MULTILINE)
    if not match or match.group(1) != "io.github.anisharyal09.anice":
        raise ValueError("APK package metadata is invalid")
    return int(match.group(2)), match.group(3)


def find_release(repository, tag, release_id=None):
    endpoint = f"repos/{repository}/releases/{release_id}" if release_id else f"repos/{repository}/releases/tags/{tag}"
    try:
        return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))
    except subprocess.CalledProcessError:
        raw = subprocess.check_output(["gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"], text=True)
        for page in json.loads(raw):
            for item in page:
                if item.get("tag_name") == tag:
                    return item
        raise


def check_release_state(repository, tag, commit):
    """Reject conflicting release state before builds and recheck before mutation."""
    _, code, prerelease = parse_tag(tag)
    raw = subprocess.check_output(["gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"], text=True)
    releases = [release for page in json.loads(raw) for release in page]
    marker = f"<!-- anice-source:{commit} -->"
    existing = next((item for item in releases if item.get("tag_name") == tag), None)
    if existing and (not existing.get("draft") or marker not in (existing.get("body") or "") or bool(existing.get("prerelease")) != prerelease):
        raise ValueError("Release already exists or draft does not match this source commit")
    if existing:
        extra = unexpected_assets(existing)
        if extra:
            raise ValueError("Draft contains unexpected assets: " + ", ".join(extra))
    for release in releases:
        if release.get("draft") or not any(isinstance(asset, dict) and asset.get("name") == NAMES[0]
                                           for asset in release.get("assets", [])):
            continue
        try:
            previous_code = parse_tag(release.get("tag_name", ""))[1]
        except ValueError:
            continue  # Nonstandard historical tags still receive the APK check before mutation.
        if previous_code >= code:
            raise ValueError("Candidate release version is not greater than a published Android release")
    return releases, existing, marker


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
    releases, existing, marker = check_release_state(repository, tag, commit)
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
            args = ["api", "--method", "POST", f"repos/{repository}/releases",
                    "-f", f"tag_name={tag}", "-f", f"name={tag}", "-f", f"body={marker}",
                    "-F", "draft=true", "-F", f"prerelease={str(prerelease).lower()}",
                    "-F", "generate_release_notes=true"]
            created = json.loads(subprocess.check_output(["gh"] + args, text=True))
            release_id = created["id"]
        else:
            release_id = existing.get("id")
        release = find_release(repository, tag, release_id)
        release_id = release.get("id", release_id)
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
                release = find_release(repository, tag, release_id)
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
        def check_verified_draft(release):
            current_assets = {item.get("name"): (item.get("id"), item.get("size")) for item in release.get("assets", [])}
            if not release.get("draft") or release.get("tag_name") != tag or marker not in (release.get("body") or "") \
                    or bool(release.get("prerelease")) != prerelease or set(current_assets) != set(NAMES) \
                    or any(current_assets.get(name) != item for name, item in verified.items()):
                raise ValueError("Draft changed before verification completed")

        check_tag_commit()
        latest = find_release(repository, tag, release_id)
        check_verified_draft(latest)
        if not latest["body"].replace(marker, "").strip():
            notes = json.loads(subprocess.check_output([
                "gh", "api", "--method", "POST", f"repos/{repository}/releases/generate-notes",
                "-f", f"tag_name={tag}", "-f", f"target_commitish={commit}"], text=True))
            description = notes.get("body") if isinstance(notes, dict) else None
            if not isinstance(description, str) or not description.replace(marker, "").strip():
                raise ValueError("Generated release description is empty or invalid")
            # Preserve maintainer edits made while GitHub generates notes.
            check_tag_commit()
            latest = find_release(repository, tag, release_id)
            check_verified_draft(latest)
            if not latest["body"].replace(marker, "").strip():
                body = f"{marker}\n\n{description.strip()}"
                latest = json.loads(subprocess.check_output([
                    "gh", "api", "--method", "PATCH", f"repos/{repository}/releases/{release_id}",
                    "-f", f"body={body}"], text=True))
                check_verified_draft(latest)
                if not latest["body"].replace(marker, "").strip():
                    raise ValueError("Draft release description was not saved")
            check_tag_commit()
        print(f"Verified draft ready for review: https://github.com/{repository}/releases")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Release draft not verified: {error}", file=sys.stderr)
        sys.exit(1)
