#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the Gate 1 CallAudioProbe as a minimal standalone app bundle.

Why a bundle rather than a bare executable: macOS privacy (TCC) and the
hardened runtime decide microphone access from the bundle's Info.plist usage
string and the process's audio-input entitlement. A bare executable built by
`swiftc` has neither, so it cannot distinguish "the endpoint has no usable
audio" from "the process was never allowed to touch audio at all". The probe
therefore ships as a tiny .app with an ad-hoc signature and an explicit
entitlements file, exactly as SessionInterchange ships as an explicit source
list built by the verification suite.

The script does not enter the production app target. Production entitlements
and Info.plist stay untouched until Gate 1 passes.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE_DIR = ROOT / "apps" / "macos" / "CallAudioProbe"
DEFAULT_OUTPUT = ROOT / "build" / "CallAudioProbe.app"
BUNDLE_ID = "io.github.anisharyal09.anice.callprobe"
EXECUTABLE = "CallAudioProbe"

SWIFT_SOURCES = [
    "main.swift",
    "ProbeRun.swift",
    "ProbeTypes.swift",
    "ProbeDiagnostics.swift",
    "ProbeMicrophone.swift",
    "HFPProbe.swift",
]

FRAMEWORKS = ["CoreAudio", "AudioToolbox", "AVFoundation", "IOBluetooth", "Foundation"]

USAGE = {
    "NSMicrophoneUsageDescription": (
        "CallAudioProbe opens the Bluetooth Hands-Free endpoint to check whether this Mac "
        "can carry call audio. The probe records no audio and discards every buffer."
    ),
    "NSBluetoothAlwaysUsageDescription": (
        "CallAudioProbe connects to the paired phone's Hands-Free service to check whether "
        "this Mac exposes usable call audio."
    ),
}

ENTITLEMENTS = {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.device.bluetooth": True,
}


def run(command: list[str], dry_run: bool) -> str:
    rendered = " ".join(str(part) for part in command)
    if dry_run:
        print("DRY RUN:", rendered)
        return ""
    try:
        result = subprocess.run(command, check=True, text=True, capture_output=True)
    except subprocess.CalledProcessError as error:
        sys.stderr.write(rendered + "\n")
        sys.stderr.write(error.stdout or "")
        sys.stderr.write(error.stderr or "")
        raise SystemExit("command failed: " + rendered)
    if result.stderr.strip():
        print(result.stderr.rstrip())
    return result.stdout


def write_info_plist(path: Path, version: str) -> None:
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": EXECUTABLE,
        "CFBundleDisplayName": "CallAudioProbe",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "LSBackgroundOnly": True,
        **USAGE,
    }
    import plistlib

    path.write_bytes(plistlib.dumps(plist, sort_keys=True))


def write_entitlements(path: Path) -> None:
    import plistlib

    path.write_bytes(plistlib.dumps(ENTITLEMENTS, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="bundle path (default: build/CallAudioProbe.app)")
    parser.add_argument("--version", default="0.1.0", help="bundle version string")
    parser.add_argument("--no-sign", action="store_true",
                        help="skip ad-hoc signing (microphone access will not be reliable)")
    parser.add_argument("--dry-run", action="store_true", help="print build commands only")
    args = parser.parse_args()

    missing = [name for name in SWIFT_SOURCES if not (PROBE_DIR / name).is_file()]
    if missing:
        raise SystemExit("missing probe sources: " + ", ".join(missing))

    output: Path = args.output

    contents = output / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    support = output.parent / ".callaudioprobe-build"
    if not args.dry_run:
        for directory in (output, support):
            if directory.exists():
                shutil.rmtree(directory)
    for directory in (macos, resources, support):
        directory.mkdir(parents=True, exist_ok=True)

    write_info_plist(contents / "Info.plist", args.version)
    # Entitlements live outside the bundle: a .entitlements file inside
    # Contents is treated by codesign as an unsigned nested code object.
    entitlements = support / "CallAudioProbe.entitlements"
    write_entitlements(entitlements)
    (contents / "PkgInfo").write_text("APPL????")

    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], args.dry_run).strip()
    if not args.dry_run and not sdk:
        raise SystemExit("could not resolve the macOS SDK path")

    command = [
        "xcrun", "swiftc",
        "-swift-version", "6",
        "-O", "-g",
        "-target", "arm64-apple-macos14.0",
        "-sdk", sdk,
        "-module-cache-path", str(support / "module-cache"),
        "-framework", FRAMEWORKS[0],
        "-framework", FRAMEWORKS[1],
        "-framework", FRAMEWORKS[2],
        "-framework", FRAMEWORKS[3],
        "-framework", FRAMEWORKS[4],
        *[str(PROBE_DIR / name) for name in SWIFT_SOURCES],
        "-o", str(macos / EXECUTABLE),
    ]
    run(command, args.dry_run)

    if not args.no_sign:
        run([
            "codesign", "--force", "--sign", "-",
            "--options", "runtime",
            "--entitlements", str(entitlements),
            "--identifier", BUNDLE_ID,
            str(output),
        ], args.dry_run)
        run(["codesign", "--verify", "--verbose=2", str(output)], args.dry_run)

    launcher = output.parent / "run-call-audio-probe.sh"
    launcher.write_text(
        "#!/bin/sh\n"
        "# SPDX-License-Identifier: GPL-3.0-or-later\n"
        "# Generated by scripts/build-call-audio-probe.py; runs the probe with its transcript on stdout.\n"
        'exec "$(dirname "$0")/CallAudioProbe.app/Contents/MacOS/CallAudioProbe" "$@"\n'
    )
    launcher.chmod(0o755)

    print(json.dumps({
        "bundle": str(output),
        "executable": str(macos / EXECUTABLE),
        "launcher": str(launcher),
        "signed": not args.no_sign,
        "sources": [str(PROBE_DIR / name) for name in SWIFT_SOURCES],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
