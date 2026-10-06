#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify actual Android Keystore ↔ macOS Keychain signatures, using test identities."""

import argparse
import base64
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "io.github.anisharyal09.anice"
TEST_CLASS = PACKAGE + ".infrastructure.identity.IdentityInterchangeTest"
REMOTE = "/sdcard/Android/data/" + PACKAGE + "/files/identity-interchange"


def run(arguments, *, cwd=ROOT, env=None, timeout=300):
    result = subprocess.run(
        [str(value) for value in arguments], cwd=cwd, env=env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
    )
    if result.returncode:
        raise RuntimeError(result.stdout.strip() or "Command failed: " + str(arguments[0]))
    return result.stdout


def require_instrumentation_pass(log):
    """Require one completed test; adb/am may exit zero for failed or skipped tests."""
    statuses = re.findall(r"^INSTRUMENTATION_STATUS_CODE: (-?\d+)\s*$", log, re.MULTILINE)
    result_codes = re.findall(r"^INSTRUMENTATION_CODE: (-?\d+)\s*$", log, re.MULTILINE)
    if (statuses != ["1", "0"] or result_codes != ["-1"]
            or not re.search(r"^OK \(1 test\)\s*$", log, re.MULTILINE)
            or any(token in log for token in ["FAILURES!!!", "INSTRUMENTATION_FAILED", "shortMsg="])):
        raise RuntimeError("Android interchange test did not pass:\n" + log)


def verify_with_openssl(bundle_path, output):
    """Use a third implementation to avoid relying solely on the two app verifiers."""
    bundle = json.loads(bundle_path.read_text())
    point = base64.b64decode(bundle["identity"]["publicKey"], validate=True)
    message = base64.b64decode(bundle["messageBase64"], validate=True)
    signature = base64.b64decode(bundle["signatureBase64"], validate=True)
    if len(point) != 65 or point[0] != 4:
        raise RuntimeError("Invalid P-256 public point in exported bundle")
    prefix = output / bundle_path.stem
    der = prefix.with_suffix(".spki.der")
    pem = prefix.with_suffix(".public.pem")
    msg = prefix.with_suffix(".message")
    sig = prefix.with_suffix(".signature.der")
    # SubjectPublicKeyInfo: id-ecPublicKey, named curve prime256v1, uncompressed point.
    der.write_bytes(bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200") + point)
    msg.write_bytes(message)
    sig.write_bytes(signature)
    run(["/usr/bin/openssl", "pkey", "-pubin", "-inform", "DER", "-in", der, "-out", pem])
    log = run(["/usr/bin/openssl", "dgst", "-sha256", "-verify", pem, "-signature", sig, msg])
    prefix.with_suffix(".openssl.log").write_text(log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="adb device serial; required when multiple devices are connected")
    parser.add_argument("--output-dir", type=Path, help="Directory for public test bundles and logs")
    parser.add_argument("--skip-build", action="store_true", help="Use already-built Android Debug/test APKs")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This harness requires macOS with Xcode and one running Android device/emulator.")

    sdk = Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", str(Path.home() / "Library/Android/sdk"))))
    adb = shutil.which("adb") or str(sdk / "platform-tools/adb")
    if not Path(adb).is_file():
        parser.error("Set ANDROID_HOME or put adb on PATH.")
    devices = [line.split()[0] for line in run([adb, "devices"]).splitlines()[1:]
               if len(line.split()) >= 2 and line.split()[1] == "device"]
    serial = args.serial
    if serial is None:
        if len(devices) != 1:
            parser.error("Connect exactly one authorized device or pass --serial.")
        serial = devices[0]
    elif serial not in devices:
        parser.error("The selected device is not connected and authorized.")
    device = [adb, "-s", serial]

    if args.output_dir:
        args.output_dir.resolve().mkdir(parents=True, exist_ok=True)
    # Every invocation owns a fresh directory; previous bundles/reports cannot satisfy this run.
    output = Path(tempfile.mkdtemp(prefix="anice-identity-interchange-",
                                  dir=args.output_dir)).resolve()
    environment = os.environ.copy()
    bundled_jdk = Path("/Applications/Android Studio.app/Contents/jbr/Contents/Home")
    if "JAVA_HOME" not in environment and bundled_jdk.is_dir():
        environment["JAVA_HOME"] = str(bundled_jdk)
    developer = environment.get("DEVELOPER_DIR") or run(["xcode-select", "-p"]).strip()
    if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
        developer = "/Applications/Xcode.app/Contents/Developer"
    environment["DEVELOPER_DIR"] = developer

    if not args.skip_build:
        print("Building Android app and isolated identity tests…", flush=True)
        log = run(["./gradlew", "assembleDebug", "assembleDebugAndroidTest"],
                  cwd=ROOT / "apps/android", env=environment, timeout=600)
        (output / "android-build.log").write_text(log)
    for apk in ["app/build/outputs/apk/debug/app-debug.apk",
                "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"]:
        run(device + ["install", "-r", ROOT / "apps/android" / apk])

    def instrument(mode):
        log = run(device + ["shell", "am", "instrument", "-w", "-r", "-e", "aniceInterchange", mode,
                           "-e", "class", TEST_CLASS,
                           PACKAGE + ".test/androidx.test.runner.AndroidJUnitRunner"])
        (output / ("android-" + mode + ".log")).write_text(log)
        require_instrumentation_pass(log)

    print("Signing with an isolated Android Keystore key…", flush=True)
    try:
        instrument("export")
        run(device + ["pull", REMOTE + "/android.json", output / "android.json"])
        print("Compiling the Mac Keychain verifier and signer…", flush=True)
        sources = [ROOT / "apps/macos/aniCe/Infrastructure/Identity" / name for name in
                   ["DeviceIdentity.swift", "IdentityService.swift", "MacIdentityStorage.swift"]]
        log = run(["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", output / "module-cache", "-framework", "Foundation",
                   "-framework", "CryptoKit", "-framework", "Security", *sources,
                   ROOT / "apps/macos/IdentityInterchange/main.swift", "-o", output / "identity-interchange"],
                  env=environment)
        (output / "mac-build.log").write_text(log)
        log = run([output / "identity-interchange", output / "android.json", output / "macos.json"])
        (output / "mac-verify.log").write_text(log)
        if not (output / "macos.json").is_file():
            raise RuntimeError("Mac verifier did not produce its public signature bundle.")
        print("Verifying the Mac signature on Android…", flush=True)
        run(device + ["push", output / "macos.json", REMOTE + "/macos.json"])
        instrument("verify")
        print("Independently checking both signatures with OpenSSL…", flush=True)
        verify_with_openssl(output / "android.json", output)
        verify_with_openssl(output / "macos.json", output)
    finally:
        instrument("cleanup")
    (output / "result.json").write_text(json.dumps({
        "androidToMac": "passed", "macToAndroid": "passed", "device": serial,
        "independentOpenSSL": "both signatures passed",
        "negativeControls": "altered messages, malformed signatures, and wrong keys rejected",
        "note": "Isolated test identities; no production private keys exported.",
    }, indent=2) + "\n")
    print("Both signature directions passed. Public bundles and logs: " + str(output))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print("Identity interchange failed: " + str(error), file=sys.stderr)
        sys.exit(1)
