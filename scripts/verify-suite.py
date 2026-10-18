#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the repository's verification gates and reject vacuous passes.

The gate deliberately distinguishes "the command exited zero" from "the tests
executed".  It fails on zero-test reports, failures, errors, crashes,
unreported tests, undocumented skips, fixture drift and missing toolchains.

This is a local acceptance tool.  It is not CI configuration and does not
replace physical radio, Keychain/Secure Enclave, minimum-OS or manual UI
acceptance; those boundaries are named in docs/A&V/TEST_AUDIT.md.
"""

import argparse
import fnmatch
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
ANDROID = ROOT / "apps" / "android"
MACOS = ROOT / "apps" / "macos"
RUST = ROOT / "core" / "rust" / "pairing"

# Floors prevent a shrunken or entirely absent suite from looking green.
# They are inventory guards, not coverage targets.
MINIMUMS = {"android-jvm": 250, "macos": 230, "rust": 4, "python": 18}
MINIMUM_CONNECTED = 10

# Environment-gated tests that cannot execute in every configuration.  They
# are listed explicitly so an unexpected skip still fails the gate.  The
# interchange harnesses run their selected tests with arguments and accept no
# skips at all; this list only covers the broad connected/hosted runs.
DOCUMENTED_ANDROID_SKIPS = {
    "HomeVisualReviewTest#nativePresentationStates",
    "ClipboardSurfaceTests#preferencesAndHistoryRenderInBothThemesWithoutClipboardReads",
    "IdentityInterchangeTest#executeInterchange",
    "LanNativeTest#rawSocketBaseline",
    "LanNativeTest#protectedTcpInterchange",
    "SessionNativeTest#protectedKeyInterchange",
    "SessionOwnershipTest#automaticPreferenceNotifiesWithoutReadingStatus",
    "FindDeviceNotificationTest#nativeTimeoutRunsFullSixtySecondsAndDoesNotExtendForDuplicateServiceStarts",
    "LanOwnershipTest#notificationDenialDoesNotPreventApprovedTransferService",
    "CompanionSetupTest#stopWinsOverSuspendedResumeSuccessAndLookupFailure",
    "CompanionBindingTest#rebindRestoresMissingPresenceReplayAndDestroyedServiceStaysRetired",
    "PhysicalSessionIdleTest#connectedIdleCpuAndNativeValidationBudget",
    "PhysicalSessionNavigationTest#authenticatedMacCloseRetiresControllerAndAllowsFreshRecovery",
    "PhysicalSessionNavigationTest#automaticOwnerSurvivesRecentsRemovalAndQuietKeepalive",
    "PhysicalSessionNavigationTest#authenticatedConnectionSurvivesPresentationHandoffs",
}

DOCUMENTED_MACOS_SKIPS = {
    "MediaTests#testPackagedOwnerAgainstCurrentlyPlayingSource",
    "CapabilityRepairTests#testExplicitPackagedPlayerToggleAndSeekAcceptance",
    "OutputVolumeTests#testExplicitPackagedOutputVolumeRoundTrip",
}


class GateError(RuntimeError):
    """A verification step failed, or its report cannot be trusted."""


@dataclass
class TestResult:
    suite: str
    name: str
    outcome: str  # passed, failed, error, skipped
    detail: str = ""

    @property
    def identifier(self):
        return self.suite + "#" + self.name if self.suite else self.name

    @property
    def short_identifier(self):
        short = self.suite.rsplit(".", 1)[-1] if self.suite else ""
        return short + "#" + self.name if short else self.name


# ---------------------------------------------------------------------------
# Report parsing


def parse_junit_files(paths):
    """Reads JUnit XML, including AGP's per-class reports, without trusting
    the process exit code or summary text alone."""
    results = []
    for path in paths:
        try:
            root = ET.parse(str(path)).getroot()
        except (ET.ParseError, OSError) as error:
            raise GateError("Cannot read JUnit report %s: %s" % (path, error))
        if root.tag not in ("testsuite", "testsuites"):
            continue

        cases = list(root.iter("testcase"))
        for case in cases:
            classname = case.get("classname") or ""
            name = case.get("name") or "(unnamed)"
            outcome = "passed"
            detail = ""
            for child in case:
                tag = child.tag.lower()
                if tag == "failure":
                    outcome = "failed"
                elif tag == "error":
                    outcome = "error"
                elif tag in ("skipped", "ignored", "disabled"):
                    outcome = "skipped"
                else:
                    continue
                if not detail:
                    detail = (child.get("message") or (child.text or "")).strip()
            results.append(TestResult(classname, name, outcome, detail))

        # A report that declares more tests than it contains is truncated.
        # Android has produced such reports after native crashes.
        if root.tag == "testsuite":
            declared = root.get("tests")
            if declared is not None:
                try:
                    declared = int(declared)
                except ValueError:
                    raise GateError("%s has a non-numeric tests attribute" % path)
                if declared != len(cases):
                    raise GateError(
                        "%s declares %d tests but contains %d test cases; "
                        "the report is incomplete" % (path, declared, len(cases))
                    )
        else:
            declared = root.get("tests")
            if declared is not None:
                try:
                    declared = int(declared)
                except ValueError:
                    raise GateError("%s has a non-numeric tests attribute" % path)
                if declared != len(cases):
                    raise GateError(
                        "%s declares %d tests but contains %d test cases; "
                        "the report is incomplete" % (path, declared, len(cases))
                    )

        # Suite-level errors indicate the runner failed outside a test case.
        for suite in root.iter("testsuite"):
            for child in list(suite):
                if child.tag in ("error", "failure"):
                    detail = (child.get("message") or (child.text or "")).strip()
                    results.append(
                        TestResult(suite.get("name") or str(path), "<suite-error>", "error", detail)
                    )
    return results


def collect_junit_reports(roots):
    paths = []
    for root in roots:
        if root.is_dir():
            paths.extend(sorted(path for path in root.rglob("*.xml") if path.is_file()))
    return paths


def cargo_results(log_path):
    text = log_path.read_text(encoding="utf-8", errors="replace")
    lines = re.findall(
        r"^test result: (\w+)\. (\d+) passed; (\d+) failed; (\d+) ignored; "
        r"(\d+) measured; (\d+) filtered out",
        text,
        re.MULTILINE,
    )
    if not lines:
        raise GateError("cargo test did not report a test result; log: %s" % log_path)
    passed = sum(int(row[1]) for row in lines)
    failed = sum(int(row[2]) for row in lines)
    ignored = sum(int(row[3]) for row in lines)
    filtered = sum(int(row[5]) for row in lines)
    if any(row[0] != "ok" for row in lines) or failed:
        raise GateError("Rust tests failed (see %s)" % log_path)
    if ignored:
        raise GateError("Rust tests were ignored (%d); a green run must execute them" % ignored)
    if filtered:
        raise GateError("Rust tests were filtered out (%d); run without a name filter" % filtered)
    if passed < MINIMUMS["rust"]:
        raise GateError("Rust executed %d tests, below the required floor of %d" % (passed, MINIMUMS["rust"]))
    print("Rust: %d passed, 0 failed, 0 ignored, 0 filtered" % passed)
    return passed


def unittest_results(log_path):
    text = log_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^Ran (\d+) tests? in ", text, re.MULTILINE)
    if not match:
        raise GateError("Python harness tests did not report a test count; log: %s" % log_path)
    count = int(match.group(1))
    if re.search(r"skipped=\d+", text):
        raise GateError("Python harness tests skipped at least one test; log: %s" % log_path)
    if re.search(r"^FAILED", text, re.MULTILINE) or count == 0:
        raise GateError("Python harness tests failed or ran zero tests; log: %s" % log_path)
    if count < MINIMUMS["python"]:
        raise GateError(
            "Python harness suite ran %d tests, below the required floor of %d" %
            (count, MINIMUMS["python"])
        )
    print("Python harness: %d passed, 0 skipped" % count)
    return count


# ---------------------------------------------------------------------------
# macOS result bundles

_XCODE_TEST_LINE = re.compile(
    r"^Test Case '-\[([^\]]+)\]' (passed|failed|skipped) \(", re.MULTILINE
)


def parse_xcode_log(log_path):
    text = log_path.read_text(encoding="utf-8", errors="replace")
    results = []
    for identifier, outcome in _XCODE_TEST_LINE.findall(text):
        pieces = identifier.rsplit(" ", 1)
        suite = pieces[0]
        name = pieces[1] if len(pieces) == 2 else identifier
        results.append(TestResult(suite, name, outcome))
    return results


def _xcresult_json(bundle, command):
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", command,
         "--path", str(bundle), "--format", "json"],
        capture_output=True, text=True,
    )
    if completed.returncode:
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None


def _walk_test_nodes(node, suite_path, out):
    if not isinstance(node, dict):
        return
    node_type = str(node.get("nodeType", ""))
    name = str(node.get("name", ""))
    result = str(node.get("result", ""))
    if node_type.lower() in ("test case", "testcase"):
        outcome = {
            "passed": "passed",
            "failed": "failed",
            "skipped": "skipped",
        }.get(result.lower(), "failed")
        out.append(TestResult("/".join(suite_path), name, outcome))
        return
    next_path = suite_path + [name] if name else suite_path
    for child in node.get("children", []) or []:
        _walk_test_nodes(child, next_path, out)


def parse_xcresult_tree(bundle):
    document = _xcresult_json(bundle, "tests")
    if not document:
        return []
    results = []
    for node in document.get("testNodes", []) or []:
        _walk_test_nodes(node, [], results)
    return results


def parse_xcode_results(bundle, log_path):
    """Checks the result bundle against xcodebuild's own test-case lines.

    A disagreement fails closed: silently accepting only the summary would
    hide an unreported or truncated test.
    """
    summary = _xcresult_json(bundle, "summary")
    logged = parse_xcode_log(log_path)
    if not logged:
        logged = parse_xcresult_tree(bundle)
    if not logged:
        raise GateError(
            "xcodebuild produced no test-case results; the suite did not run "
            "(log: %s)" % log_path
        )

    if summary is not None:
        total = summary.get("totalTestCount")
        if isinstance(total, int):
            if total == 0:
                raise GateError("xcresult reports zero tests; xcodebuild did not execute the suite")
            if total != len(logged):
                raise GateError(
                    "xcodebuild logged %d test cases but the result bundle reports %d; "
                    "refusing to accept a partial report" % (len(logged), total)
                )
        skipped = summary.get("skippedTests")
        if isinstance(skipped, int):
            logged_skips = sum(1 for result in logged if result.outcome == "skipped")
            if skipped != logged_skips:
                raise GateError(
                    "xcresult reports %d skipped tests but the log contains %d; "
                    "refusing to accept a partial report" % (skipped, logged_skips)
                )
        failed = summary.get("failedTests")
        if isinstance(failed, int):
            logged_failures = sum(1 for result in logged if result.outcome in ("failed", "error"))
            if failed != logged_failures:
                raise GateError(
                    "xcresult reports %d failed tests but the log contains %d"
                    % (failed, logged_failures)
                )
    return logged


# ---------------------------------------------------------------------------
# Gate validation


def _matches(result, patterns):
    candidates = {result.identifier, result.short_identifier, result.name}
    return any(fnmatch.fnmatchcase(candidate, pattern)
               for candidate in candidates for pattern in patterns)


def validate_results(results, label, minimum, documented=(), extra=()):
    if len(results) < minimum:
        raise GateError(
            "%s executed %d tests, below the required floor of %d; "
            "a green run must execute real tests" % (label, len(results), minimum)
        )
    failed = [result for result in results if result.outcome in ("failed", "error")]
    skipped = [result for result in results if result.outcome == "skipped"]
    patterns = set(documented) | set(extra)
    unknown = [result for result in skipped if not _matches(result, patterns)]
    passed = [result for result in results if result.outcome == "passed"]

    if failed:
        lines = ["%s failed %d test(s):" % (label, len(failed))]
        lines += ["  " + result.identifier + (": " + result.detail if result.detail else "")
                  for result in failed]
        raise GateError("\n".join(lines))
    if unknown:
        lines = [
            "%s skipped %d undocumented test(s); green does not mean executed:"
            % (label, len(unknown))
        ]
        lines += ["  " + result.identifier + (": " + result.detail if result.detail else "")
                  for result in unknown]
        lines.append("Pass --allow-skip PATTERN only for a reviewed environment gate.")
        raise GateError("\n".join(lines))
    if not passed:
        raise GateError("%s executed no passing tests" % label)

    print(
        "%s: %d passed, %d failed, %d documented skip(s) (floor %d)"
        % (label, len(passed), 0, len(skipped), minimum)
    )
    for result in skipped:
        print("  documented skip: " + result.identifier)
    return len(passed), len(skipped)


# ---------------------------------------------------------------------------
# Process and toolchain helpers


def print_tail(path, lines=80):
    try:
        text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return
    print("\n".join(text[-lines:]))


def run_step(label, command, artifacts, cwd=ROOT, env=None, timeout=1800):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-").lower()
    log = artifacts / (slug + ".log")
    printable = " ".join(shlex.quote(str(part)) for part in command)
    print("\n[%s] %s" % (label, printable), flush=True)
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        try:
            completed = subprocess.run(
                [str(part) for part in command], cwd=str(cwd), env=env,
                stdout=stream, stderr=subprocess.STDOUT, timeout=timeout,
            )
        except FileNotFoundError as error:
            raise GateError("%s could not start: %s" % (label, error))
        except subprocess.TimeoutExpired:
            print_tail(log)
            raise GateError("%s timed out after %d seconds; log: %s" % (label, timeout, log))
    elapsed = time.monotonic() - started
    if completed.returncode:
        print_tail(log)
        raise GateError(
            "%s failed with exit %d; log: %s" % (label, completed.returncode, log)
        )
    print("[%s] completed in %.1fs (log: %s)" % (label, elapsed, log))
    return log


def toolchain_env():
    env = os.environ.copy()
    if not env.get("JAVA_HOME"):
        bundled = Path("/Applications/Android Studio.app/Contents/jbr/Contents/Home")
        if bundled.is_dir():
            env["JAVA_HOME"] = str(bundled)
    if not env.get("DEVELOPER_DIR"):
        developer = ""
        try:
            developer = subprocess.check_output(
                ["xcode-select", "-p"], text=True, stderr=subprocess.DEVNULL
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            pass
        if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
            developer = "/Applications/Xcode.app/Contents/Developer"
        if (Path(developer) / "Platforms/MacOSX.platform").is_dir():
            env["DEVELOPER_DIR"] = developer
    # Hosted Keychain tests skip unless this reaches the test runner.
    env["TEST_RUNNER_ANICE_RUN_KEYCHAIN_TESTS"] = "1"
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    # Cargo may be installed but absent from a non-login shell's PATH.
    if not shutil.which("cargo", path=env.get("PATH", "")):
        cargo_bin = Path.home() / ".cargo" / "bin"
        if (cargo_bin / "cargo").is_file():
            env["PATH"] = str(cargo_bin) + os.pathsep + env.get("PATH", "")
    return env


def vector_interpreter(explicit):
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    candidates.append(ROOT / ".venv" / "bin" / "python")
    candidates.append(Path(sys.executable))
    for candidate in candidates:
        if not candidate.is_file():
            continue
        probe = subprocess.run(
            [str(candidate), "-I", "-c", "import cryptography, cbor2"],
            capture_output=True, text=True,
        )
        if probe.returncode == 0:
            # Do not resolve symlinks: a venv's python is a symlink to the
            # base interpreter, and resolving it bypasses pyvenv.cfg.
            return os.path.abspath(str(candidate))
    raise GateError(
        "The independent vector oracles need the pinned Python dependencies "
        "(cryptography and cbor2). Create an environment once and pass it explicitly:\n"
        "  python3 -m venv .venv\n"
        "  .venv/bin/python -m pip install -r protocol/test-vectors/session/requirements.txt\n"
        "  python3 scripts/verify-suite.py fast --vector-python .venv/bin/python"
    )


def find_adb():
    candidate = shutil.which("adb")
    if candidate:
        return candidate
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(variable):
            path = Path(os.environ[variable]) / "platform-tools" / "adb"
            if path.is_file():
                return str(path)
    path = Path.home() / "Library" / "Android" / "sdk" / "platform-tools" / "adb"
    if path.is_file():
        return str(path)
    raise GateError("adb is not available; set ANDROID_HOME or put adb on PATH")


def connected_devices(adb):
    completed = subprocess.run([adb, "devices"], capture_output=True, text=True)
    if completed.returncode:
        raise GateError("adb devices failed: " + completed.stdout.strip())
    return [
        line.split()[0]
        for line in completed.stdout.splitlines()[1:]
        if len(line.split()) >= 2 and line.split()[1] == "device"
    ]


def selected_device(adb, serial):
    devices = connected_devices(adb)
    if serial:
        if serial not in devices:
            raise GateError("The selected device %s is not connected and authorized" % serial)
        return serial
    if len(devices) == 1:
        return devices[0]
    if not devices:
        return None
    raise GateError("Multiple devices are connected; pass --serial")


# ---------------------------------------------------------------------------
# Steps


def run_structure(artifacts):
    run_step("Structure and documentation", [sys.executable, SCRIPTS / "check-structure.py"], artifacts)


def run_vector_checks(interpreter, artifacts):
    checks = [
        ("Clipboard vectors", ROOT / "protocol/test-vectors/clipboard/generate_clipboard_vectors.py", ["--check"]),
        ("Transfer vectors", ROOT / "protocol/test-vectors/transfer/generate_transfer_vectors.py", ["--check"]),
        ("Media vectors", ROOT / "protocol/test-vectors/media/generate.py", ["--check"]),
        ("Find Device vectors", ROOT / "protocol/test-vectors/find-device/generate.py", ["--check"]),
        ("Identity vectors", ROOT / "protocol/test-vectors/generate_identity_vectors.py", ["--check"]),
        ("Pairing vectors", ROOT / "protocol/test-vectors/generate_pairing_vectors.py", ["--check"]),
        ("Session handshake vectors", ROOT / "protocol/test-vectors/session/generate_session_vectors.py", ["--check"]),
        ("Session control vectors", ROOT / "protocol/test-vectors/session/generate_control_vectors.py", ["--check"]),
        ("Session record vectors", ROOT / "protocol/test-vectors/session/generate_record_vectors.py", ["--check"]),
        ("LAN framing vectors", ROOT / "protocol/test-vectors/lan/generate_lan_vectors.py", ["--check"]),
        ("Bulk probe vectors", ROOT / "protocol/test-vectors/lan/generate_bulk_probe_vectors.py", ["--check"]),
        ("LAN transfer vectors", ROOT / "protocol/test-vectors/lan/generate_bulk_probe_vectors.py", ["--check", "--lan-transfer"]),
    ]
    for label, script, extra in checks:
        run_step(label, [interpreter, script] + extra, artifacts, cwd=script.parent)
    print("Vector oracles: %d independent fixture checks passed" % len(checks))


def run_python_meta_tests(env, artifacts):
    log = run_step(
        "Python harness meta-tests",
        [sys.executable, "-m", "unittest", "discover", "-s", str(SCRIPTS), "-p", "test_*.py", "-v"],
        artifacts, env=env,
    )
    return unittest_results(log)


def run_rust(env, artifacts):
    log = run_step(
        "Rust pairing tests",
        ["cargo", "test", "--locked"],
        artifacts, cwd=RUST, env=env, timeout=900,
    )
    return cargo_results(log)


def run_android_jvm(env, artifacts):
    reports = ANDROID / "app/build/test-results/testDebugUnitTest"
    shutil.rmtree(reports, ignore_errors=True)
    shutil.rmtree(ANDROID / "app/build/reports/tests/testDebugUnitTest", ignore_errors=True)
    run_step(
        "Android JVM tests and lint",
        [ANDROID / "gradlew", "--console=plain", "testDebugUnitTest", "lintDebug"],
        artifacts, cwd=ANDROID, env=env, timeout=2400,
    )
    paths = collect_junit_reports([reports])
    if not paths:
        raise GateError(
            "Android JVM run produced no JUnit reports; the tests did not execute "
            "(expected %s)" % reports
        )
    results = parse_junit_files(paths)
    validate_results(results, "Android JVM", MINIMUMS["android-jvm"])


def build_session_helper(env, artifacts):
    output = artifacts / "session-interchange-helper"
    sources = [
        MACOS / "aniCe/Infrastructure/Identity" / name
        for name in ("DeviceIdentity.swift", "IdentityService.swift", "MacIdentityStorage.swift")
    ]
    sources += [
        MACOS / "aniCe/Infrastructure/Pairing" / name
        for name in ("PairingCodec.swift", "PeerTrustStore.swift")
    ]
    sources += [
        MACOS / "aniCe/Infrastructure/Session" / name
        for name in ("SessionCbor.swift", "SessionCrypto.swift",
                     "SessionHandshakeEngine.swift", "SecureSession.swift")
    ]
    sources += [
        MACOS / "aniCe/Infrastructure/Bluetooth/GattFraming.swift",
        MACOS / "SessionInterchange/main.swift",
    ]
    run_step(
        "Build session interchange helper",
        [
            "xcrun", "swiftc", "-swift-version", "6", "-D", "ANICE_DEVELOPMENT_KEYCHAIN",
            "-module-cache-path", str(artifacts / "swift-module-cache"),
            "-framework", "Foundation", "-framework", "CryptoKit",
            "-framework", "Security", "-framework", "Network",
            *sources, "-o", str(output),
        ],
        artifacts, env=env, timeout=600,
    )
    return output


def run_device_checks(args, env, artifacts, documented_android):
    adb = find_adb()
    serial = selected_device(adb, args.serial)
    if serial is None:
        if args.allow_no_device:
            print("\nDEVICE CHECKS NOT EXECUTED: no authorized device is connected (--allow-no-device).")
            return
        raise GateError(
            "Device mode requires one authorized Android device; pass --serial, "
            "or --allow-no-device to record that device coverage was not run"
        )

    serial_args = ["--serial", serial]
    run_step(
        "Identity interchange",
        [sys.executable, SCRIPTS / "verify-identity-interchange.py",
         *serial_args, "--output-dir", str(artifacts / "identity-interchange")],
        artifacts, env=env, timeout=1800,
    )
    run_step(
        "LAN interchange",
        [sys.executable, SCRIPTS / "verify-lan-interchange.py",
         *serial_args, "--output", str(artifacts / "lan-interchange")],
        artifacts, env=env, timeout=2400,
    )
    helper = args.session_mac_binary or build_session_helper(env, artifacts)
    run_step(
        "Session interchange",
        [sys.executable, SCRIPTS / "verify-session-interchange.py",
         *serial_args, "--mac-binary", str(helper),
         "--output", str(artifacts / "session-interchange")],
        artifacts, env=env, timeout=2400,
    )
    run_connected_android(env, artifacts, documented_android)


def run_connected_android(env, artifacts, documented):
    for folder in (
        ANDROID / "app/build/outputs/androidTest-results/connected",
        ANDROID / "app/build/test-results/connectedDebugAndroidTest",
        ANDROID / "app/build/reports/androidTests/connected",
    ):
        shutil.rmtree(folder, ignore_errors=True)
    run_step(
        "Android connected tests",
        [ANDROID / "gradlew", "--console=plain", "connectedDebugAndroidTest"],
        artifacts, cwd=ANDROID, env=env, timeout=3600,
    )
    paths = collect_junit_reports([
        ANDROID / "app/build/outputs/androidTest-results/connected",
        ANDROID / "app/build/test-results/connectedDebugAndroidTest",
    ])
    if not paths:
        raise GateError("Android connected run produced no JUnit reports; the tests did not execute")
    validate_results(
        parse_junit_files(paths), "Android connected", MINIMUM_CONNECTED,
        documented=documented,
    )


# ---------------------------------------------------------------------------
# Entry point


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("fast", "device", "all"))
    parser.add_argument("--android", action="store_true", help="include Android host checks")
    parser.add_argument("--macos", action="store_true", help="include macOS hosted checks")
    parser.add_argument("--serial", help="adb serial for device mode")
    parser.add_argument("--allow-no-device", action="store_true",
                        help="record that device checks were not executed instead of failing")
    parser.add_argument("--vector-python", type=Path,
                        help="interpreter with cryptography and cbor2 installed")
    parser.add_argument("--session-mac-binary", type=Path,
                        help="use an already-built SessionInterchange helper")
    parser.add_argument("--allow-skip", action="append", default=[], metavar="PATTERN",
                        help="allow one reviewed environment-gated test pattern")
    parser.add_argument("--strict-skips", action="store_true",
                        help="also reject the documented manual/real-player skips")
    parser.add_argument("--skip-rust", action="store_true", help="skip the Rust suite")
    args = parser.parse_args(argv)

    artifacts = Path(tempfile.mkdtemp(prefix="anice-verify-suite-")).resolve()
    print("Verification artifacts: " + str(artifacts))
    env = toolchain_env()
    documented_android = () if args.strict_skips else DOCUMENTED_ANDROID_SKIPS
    documented_macos = () if args.strict_skips else DOCUMENTED_MACOS_SKIPS

    try:
        if args.mode in ("fast", "all"):
            if args.android or args.macos:
                host_platforms = [name for name, selected in (("android", args.android), ("macos", args.macos)) if selected]
            else:
                host_platforms = ["android", "macos"]

            run_structure(artifacts)
            interpreter = vector_interpreter(args.vector_python)
            run_vector_checks(interpreter, artifacts)
            run_python_meta_tests(env, artifacts)
            if not args.skip_rust:
                run_rust(env, artifacts)
            if "android" in host_platforms:
                run_android_jvm(env, artifacts)
            if "macos" in host_platforms:
                run_macos_with_skips(env, artifacts, documented_macos, args.allow_skip)

        if args.mode in ("device", "all"):
            run_device_checks(args, env, artifacts, documented_android)
    except GateError as error:
        print("\nVERIFICATION FAILED: " + str(error), file=sys.stderr)
        print("Artifacts: " + str(artifacts), file=sys.stderr)
        return 1

    print("\nVERIFICATION PASSED")
    print("Artifacts: " + str(artifacts))
    return 0


def run_macos_with_skips(env, artifacts, documented, extra):
    derived = artifacts / "macos-derived-data"
    bundle = artifacts / "macos.xcresult"
    if bundle.exists():
        shutil.rmtree(bundle)
    log = run_step(
        "macOS hosted tests",
        [
            "xcodebuild", "-project", "aniCe.xcodeproj", "-scheme", "aniCe",
            "-configuration", "Debug", "-derivedDataPath", str(derived),
            "-destination", "platform=macOS", "-resultBundlePath", str(bundle), "test",
        ],
        artifacts, cwd=MACOS, env=env, timeout=2400,
    )
    results = parse_xcode_results(bundle, log)
    validate_results(
        results, "macOS hosted", MINIMUMS["macos"],
        documented=documented, extra=extra,
    )


if __name__ == "__main__":
    raise SystemExit(main())
