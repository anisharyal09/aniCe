#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate release tags and produce deterministic Android build numbers."""
import argparse
import re

_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\.([1-9][0-9]*))?\Z")


def parse_tag(tag: str) -> tuple[str, int, bool]:
    match = _TAG.fullmatch(tag)
    if not match:
        raise ValueError("Invalid release tag")
    major, minor, patch = map(int, match.group(1, 2, 3))
    stage, number_text = match.group(4, 5)
    number = int(number_text) if number_text else 0
    if major > 2000 or minor > 99 or patch > 99 or (stage and number > 19):
        raise ValueError("Release tag exceeds supported version bounds")
    stage_code = {None: 99, "alpha": number, "beta": 20 + number, "rc": 40 + number}[stage]
    return tag[1:], major * 1_000_000 + minor * 10_000 + patch * 100 + stage_code, bool(stage)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    args = parser.parse_args()
    try:
        version, code, prerelease = parse_tag(args.tag)
    except ValueError as error:
        parser.error(str(error))
    print(f"version={version}\ncode={code}\nprerelease={str(prerelease).lower()}")


if __name__ == "__main__":
    main()
