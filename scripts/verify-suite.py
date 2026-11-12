#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the repository's verification gates and reject vacuous passes.

The gate deliberately distinguishes "the command exited zero" from "the tests
executed".  It fails on zero-test reports, failures, errors, crashes,
unreported tests, undocumented skips, fixture drift and missing toolchains.

The gate runs locally and in CI; physical radio, protected-storage,
minimum-OS and native interaction behavior require separate runtime checks.

Use --only LANE (repeatable) to invoke one workflow gate without running the
local aggregate.  Lanes are the only interface workflow YAML needs.
"""

import argparse
import fnmatch
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
ANDROID = ROOT / "apps" / "android"
MACOS = ROOT / "apps" / "macos"
RUST = ROOT / "core" / "rust" / "pairing"

# Floors prevent a shrunken or entirely absent suite from looking green.
# They are inventory guards, not coverage targets.
MINIMUMS = {
    "android-jvm": 250,
    "macos": 230,
    "rust": 4,
    "python": 18,
    "ci-policy": 12,
}
MINIMUM_CONNECTED = 30

# A workflow lane is the only unit CI selects.  Keeping this mapping in the
# verifier prevents YAML from acquiring its own test inventory or ordering.
LANES = {
    "ci-integrity": ("ci-integrity",),
    "contracts": ("structure", "vectors", "python"),
    "rust": ("rust",),
    "android": ("android",),
    "macos": ("macos",),
    "connected": ("connected",),
    "interchange": ("interchange",),
}
SUITE_ORDER = (
    "ci-integrity", "structure", "vectors", "python", "rust",
    "android", "macos", "connected", "interchange",
)

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
    "PhysicalSessionNavigationTest#physicalMediaCommandLatency",
    "PhysicalSessionNavigationTest#physicalReplySubscription",
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

    def __init__(self, message, file=None, line=None):
        super().__init__(message)
        self.file = file
        self.line = line


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


@dataclass
class NotExecuted:
    """An explicit, recorded omission rather than a passing suite."""

    reason: str


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
                    # A reviewed skip never cancels failure evidence in the same test case.
                    if outcome in ("failed", "error"):
                        continue
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

        # Wrapper totals can be absent or consistent while a nested suite is still truncated.
        for nested in root.iter():
            if nested is root or nested.tag not in ("testsuite", "testsuites"):
                continue
            declared = nested.get("tests")
            if declared is None:
                continue
            try:
                declared = int(declared)
            except ValueError:
                raise GateError("%s has a non-numeric nested tests attribute" % path)
            contained = sum(1 for _ in nested.iter("testcase"))
            if declared != contained:
                raise GateError("%s nested suite declares %d tests but contains %d; the report is incomplete"
                                % (path, declared, contained))

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


def unittest_results(log_path, minimum=None, label="Python harness"):
    text = log_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^Ran (\d+) tests? in ", text, re.MULTILINE)
    if not match:
        raise GateError("%s tests did not report a test count; log: %s" % (label, log_path))
    count = int(match.group(1))
    required = MINIMUMS["python"] if minimum is None else minimum
    if re.search(r"skipped=\d+", text):
        raise GateError("%s tests skipped at least one test; log: %s" % (label, log_path))
    if re.search(r"^FAILED", text, re.MULTILINE) or count == 0:
        raise GateError("%s tests failed or ran zero tests; log: %s" % (label, log_path))
    # A count line alone can survive a truncated run; expected failures are not passing tests.
    if not re.search(r"^OK\s*$", text, re.MULTILINE):
        raise GateError("%s tests lack a complete, unconditional OK result; log: %s" % (label, log_path))
    if count < required:
        raise GateError(
            "%s suite ran %d tests, below the required floor of %d" %
            (label, count, required)
        )
    print("%s: %d passed, 0 skipped" % (label, count))
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


def _xcresult_json(bundle, command, env=None):
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", command,
         "--path", str(bundle), "--format", "json"],
        capture_output=True, text=True, env=env,
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


def parse_xcresult_tree(bundle, env=None):
    document = _xcresult_json(bundle, "tests", env=env)
    if not document:
        return []
    results = []
    for node in document.get("testNodes", []) or []:
        _walk_test_nodes(node, [], results)
    return results


def parse_xcode_results(bundle, log_path, env=None):
    """Checks the result bundle against xcodebuild's own test-case lines.

    A disagreement fails closed: silently accepting only the summary would
    hide an unreported or truncated test.
    """
    summary = _xcresult_json(bundle, "summary", env=env)
    logged = parse_xcode_log(log_path)
    if not logged:
        logged = parse_xcresult_tree(bundle, env=env)
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
    # Prefix subprocess output so a diagnostic cannot inject workflow commands.
    print("\n".join("| " + line for line in text[-lines:]))


def write_json(path, document):
    # Replace the report only after the full JSON is written; readers must not see a partial update.
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def markdown_summary(summary):
    """Renders the saved evidence without inventing counts or coverage claims."""
    lines = ["## Verification summary", "", "| Suite | Status | Evidence |", "| --- | --- | --- |"]
    for name in SUITE_ORDER:
        row = summary.get("suites", {}).get(name)
        if not row or row.get("status") == "not_selected":
            continue
        evidence = []
        for key in ("passed", "failed", "documented_skips", "checks",
                    "policy_tests", "harnesses", "actionlint", "xcode",
                    "arch", "ble_verified", "manual_acceptance"):
            if key in row:
                evidence.append("%s %s" % (key.replace("_", " "), row[key]))
        if row.get("reason"):
            evidence.append(str(row["reason"]))
        lines.append("| %s | %s | %s |" % (name, row.get("status", "unknown"), "; ".join(evidence) or "-"))
    lines.extend(["", "**Overall: %s**" % summary.get("status", "unknown")])
    if summary.get("errors"):
        lines.extend(["", "Errors:"])
        lines.extend("- " + str(error).replace("\n", " ") for error in summary["errors"])
    return "\n".join(lines) + "\n"


def append_step_summary(summary):
    """Publishes the same evidence to the job summary when GitHub provides one."""
    destination = os.environ.get("GITHUB_STEP_SUMMARY")
    if not destination:
        return
    try:
        with open(destination, "a", encoding="utf-8") as stream:
            stream.write(markdown_summary(summary))
    except OSError as error:
        # The JSON report remains the acceptance evidence; reporting failure is visible but not green-washing.
        print("::warning::Cannot append the verification step summary: %s" % error, file=sys.stderr)


def workflow_error(error):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    def escape(value, property_value=False):
        # Actions interprets newlines and property separators; test output must remain message text.
        value = str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        return value.replace(":", "%3A").replace(",", "%2C") if property_value else value
    properties = []
    # A gate failure may have no source location; omit it rather than point at an unrelated line.
    if getattr(error, "file", None):
        properties.append("file=" + escape(error.file, True))
    if getattr(error, "line", None):
        properties.append("line=" + str(int(error.line)))
    print("::error" + (" " + ",".join(properties) if properties else "") + "::" + escape(error), file=sys.stderr)


def run_step(label, command, artifacts, cwd=ROOT, env=None, timeout=1800):
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-").lower()
    log = artifacts / (slug + ".log")
    printable = " ".join(shlex.quote(str(part)) for part in command)
    print("\n[%s] %s" % (label, printable), flush=True)
    started = time.monotonic()
    metadata = artifacts / (slug + ".command.json")
    record = {"label": label, "command": [str(part) for part in command],
              "cwd": str(cwd), "log": str(log), "status": "running",
              "exit_code": None, "timeout_seconds": timeout, "elapsed_seconds": 0}
    # Persist intent before launch so an interrupted run still identifies its active command.
    write_json(metadata, record)
    failure = None
    try:
        with log.open("w", encoding="utf-8") as stream:
            completed = subprocess.run(
                [str(part) for part in command], cwd=str(cwd), env=env,
                stdout=stream, stderr=subprocess.STDOUT, timeout=timeout,
            )
        record["exit_code"] = completed.returncode
        if completed.returncode:
            failure = GateError("%s failed with exit %d; log: %s" % (label, completed.returncode, log))
    except OSError as error:
        failure = GateError("%s could not run: %s; log: %s" % (label, error, log))
    except subprocess.TimeoutExpired:
        failure = GateError("%s timed out after %s seconds; log: %s" % (label, timeout, log))
    except KeyboardInterrupt:
        failure = GateError("%s interrupted; log: %s" % (label, log))
    elapsed = time.monotonic() - started
    # Command completion is separate from acceptance: the caller still validates test evidence.
    record.update(status="failed" if failure else "completed", elapsed_seconds=round(elapsed, 3))
    if failure:
        record["error"] = str(failure)
    try:
        write_json(metadata, record)
    except OSError as error:
        # A reporting failure must retain the original command failure for diagnosis.
        raise GateError((str(failure) + "; " if failure else "") + "Cannot save command diagnostics: " + str(error)) from error
    if failure:
        print_tail(log)
        raise failure
    print("[%s] completed in %.1fs (log: %s)" % (label, elapsed, log))
    return log


def toolchain_env(android=False, macos=False, require_xcode=False):
    # Probe only selected platforms; Linux Android checks have no Xcode dependency.
    env = os.environ.copy()
    if android and not env.get("ANDROID_HOME"):
        if env.get("ANDROID_SDK_ROOT"):
            # Keep the two names consistent when only the legacy variable is set.
            env["ANDROID_HOME"] = env["ANDROID_SDK_ROOT"]
        else:
            for candidate in (Path.home() / "Library" / "Android" / "sdk",
                              Path.home() / "Android" / "Sdk"):
                if candidate.is_dir():
                    env["ANDROID_HOME"] = str(candidate)
                    env["ANDROID_SDK_ROOT"] = str(candidate)
                    break
    if android and not env.get("JAVA_HOME"):
        bundled = Path("/Applications/Android Studio.app/Contents/jbr/Contents/Home")
        if bundled.is_dir():
            env["JAVA_HOME"] = str(bundled)
    if macos:
        developer = env.get("DEVELOPER_DIR", "")
        if developer and not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
            # A pin must name a complete Xcode; falling back would hide a broken runner image.
            raise GateError("DEVELOPER_DIR is not a full Xcode developer directory: " + developer)
        if not developer:
            try:
                developer = subprocess.check_output(
                    ["xcode-select", "-p"], text=True, stderr=subprocess.DEVNULL
                ).strip()
            except (OSError, subprocess.CalledProcessError):
                developer = ""
            if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
                developer = "/Applications/Xcode.app/Contents/Developer"
            if (Path(developer) / "Platforms/MacOSX.platform").is_dir():
                env["DEVELOPER_DIR"] = developer
        if require_xcode and not env.get("DEVELOPER_DIR"):
            raise GateError("macOS hosted tests require a full Xcode installation")
    # Hosted Keychain tests skip unless this reaches the test runner.
    if macos:
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


def find_adb(env=None):
    source = env if env is not None else os.environ
    candidate = shutil.which("adb", path=source.get("PATH", ""))
    if candidate:
        return candidate
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if source.get(variable):
            path = Path(source[variable]) / "platform-tools" / "adb"
            if path.is_file():
                return str(path)
    for candidate_dir in (
        Path.home() / "Library" / "Android" / "sdk",
        Path.home() / "Android" / "Sdk",
        Path("/usr/local/lib/android/sdk"),
        Path("/usr/lib/android-sdk"),
    ):
        path = candidate_dir / "platform-tools" / "adb"
        if path.is_file():
            return str(path)
    raise GateError("adb is not available; set ANDROID_HOME or put adb on PATH")


def connected_devices(adb, env=None):
    completed = subprocess.run([adb, "devices"], capture_output=True, text=True, env=env)
    if completed.returncode:
        raise GateError("adb devices failed: " + completed.stdout.strip())
    return [
        line.split()[0]
        for line in completed.stdout.splitlines()[1:]
        if len(line.split()) >= 2 and line.split()[1] == "device"
    ]


def selected_device(adb, serial, env=None):
    devices = connected_devices(adb, env=env)
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
        ("SMS vectors", ROOT / "protocol/test-vectors/sms/generate_sms_vectors.py", ["--check"]),
    ]
    for label, script, extra in checks:
        run_step(label, [interpreter, script] + extra, artifacts, cwd=script.parent)
    print("Vector oracles: %d independent fixture checks passed" % len(checks))
    return len(checks)


def run_python_meta_tests(env, artifacts):
    log = run_step(
        "Python harness meta-tests",
        [sys.executable, "-m", "unittest", "discover", "-s", str(SCRIPTS), "-p", "test_*.py", "-v"],
        artifacts, env=env,
    )
    return unittest_results(log)


def run_ci_integrity(env, artifacts):
    actionlint = shutil.which("actionlint", path=env.get("PATH"))
    if not actionlint:
        raise GateError(
            "actionlint is required for the ci-integrity lane; install the pinned "
            "release or put actionlint on PATH"
        )
    run_step("Workflow syntax", [actionlint, "-no-color"], artifacts, env=env)
    log = run_step(
        "Workflow policy tests",
        [sys.executable, "-m", "unittest", "discover", "-s", str(SCRIPTS),
         "-p", "test_ci_workflow.py", "-v"],
        artifacts, env=env,
    )
    policy_tests = unittest_results(
        log, minimum=MINIMUMS["ci-policy"], label="Workflow policy",
    )
    return {"actionlint": "passed", "policy_tests": policy_tests}


def run_rust(env, artifacts):
    log = run_step(
        "Rust pairing tests",
        ["cargo", "test", "--locked"],
        artifacts, cwd=RUST, env=env, timeout=900,
    )
    return cargo_results(log)


def run_android_jvm(env, artifacts):
    reports = ANDROID / "app/build/test-results/testDebugUnitTest"
    # Old XML could make a runner that executes nothing appear successful. Cleanup errors must fail.
    for folder in (reports, ANDROID / "app/build/reports/tests/testDebugUnitTest"):
        if folder.exists():
            shutil.rmtree(folder)
    run_step(
        "Android JVM tests, lint, and test compilation",
        # Dependency caches remain usable, but cached task outputs must not replace test execution.
        [
            ANDROID / "gradlew", "--console=plain", "--no-build-cache",
            "testDebugUnitTest", "lintDebug", "assembleDebugAndroidTest",
        ],
        artifacts, cwd=ANDROID, env=env, timeout=2400,
    )
    paths = collect_junit_reports([reports])
    if not paths:
        raise GateError(
            "Android JVM run produced no JUnit reports; the tests did not execute "
            "(expected %s)" % reports
        )
    results = parse_junit_files(paths)
    # Keep individual results even when the acceptance checks below reject the suite.
    write_json(artifacts / "android-tests.json", [asdict(result) for result in results])
    return validate_results(results, "Android JVM", MINIMUMS["android-jvm"])


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
        for name in ("SessionCbor.swift", "SessionControl.swift", "SessionCrypto.swift",
                     "SessionEnvelope.swift", "SessionHandshakeEngine.swift", "SessionConnection.swift",
                     "SecureSession.swift")
    ]
    sources += [
        MACOS / "aniCe/Infrastructure/Bluetooth/GattFraming.swift",
        MACOS / "aniCe/Infrastructure/LAN/LanFraming.swift",
        MACOS / "aniCe/Infrastructure/LAN/LanTcpTransport.swift",
        MACOS / "SessionInterchange/main.swift",
        MACOS / "SessionInterchange/TcpInterchange.swift",
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


def selected_serial_or_skip(args, env=None):
    adb = find_adb(env=env)
    serial = selected_device(adb, args.serial, env=env)
    if serial is not None:
        return serial
    if args.allow_no_device:
        print("\nDEVICE CHECKS NOT EXECUTED: no authorized device is connected (--allow-no-device).")
        return None
    raise GateError(
        "Device lanes require one authorized Android device or emulator; pass --serial, "
        "or ensure emulator is booted (adb devices reported no authorized device)"
    )


def run_interchange_checks(args, env, artifacts):
    serial = selected_serial_or_skip(args, env=env)
    if serial is None:
        return NotExecuted("No authorized device (--allow-no-device)")

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
    return {
        "harnesses": 3,
        "ble_verified": False,
        "manual_acceptance": "pending",
    }


def run_connected_checks(args, env, artifacts, documented_android):
    serial = selected_serial_or_skip(args, env=env)
    if serial is None:
        return NotExecuted("No authorized device (--allow-no-device)")
    # Gradle otherwise chooses its own target when more than one device is attached.
    isolated = env.copy()
    isolated["ANDROID_SERIAL"] = serial
    if not serial.startswith("emulator-"):
        return run_connected_android(isolated, artifacts, documented_android)
    # The emulator action shuts the device down as soon as this command returns.
    # Capture runtime evidence here, not in a later workflow step.
    failed = False
    try:
        return run_connected_android(isolated, artifacts, documented_android)
    except BaseException:
        failed = True
        raise
    finally:
        try:
            run_step(
                "Emulator logcat", [find_adb(env=isolated), "-s", serial, "logcat", "-d"],
                artifacts, env=isolated, timeout=30,
            )
        except (GateError, OSError) as error:
            if not failed:
                raise
            # Keep the original test failure rather than replace it with diagnostics failure.
            print("Cannot collect emulator logcat:", file=sys.stderr)
            print("\n".join("| " + line for line in str(error).splitlines()), file=sys.stderr)


def run_connected_android(env, artifacts, documented):
    # Connected tests need fresh reports for the same reason as the host JVM suite.
    for folder in (
        ANDROID / "app/build/outputs/androidTest-results/connected",
        ANDROID / "app/build/test-results/connectedDebugAndroidTest",
        ANDROID / "app/build/reports/androidTests/connected",
    ):
        if folder.exists():
            shutil.rmtree(folder)
    run_step(
        "Android connected tests",
        [ANDROID / "gradlew", "--console=plain", "--no-build-cache", "connectedDebugAndroidTest"],
        artifacts, cwd=ANDROID, env=env, timeout=3600,
    )
    paths = collect_junit_reports([
        ANDROID / "app/build/outputs/androidTest-results/connected",
        ANDROID / "app/build/test-results/connectedDebugAndroidTest",
    ])
    if not paths:
        raise GateError("Android connected run produced no JUnit reports; the tests did not execute")
    results = parse_junit_files(paths)
    write_json(artifacts / "android-connected-tests.json", [asdict(result) for result in results])
    return validate_results(
        results, "Android connected", MINIMUM_CONNECTED,
        documented=documented,
    )


# ---------------------------------------------------------------------------
# Entry point


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("fast", "device", "all"),
                        help="legacy aggregate mode; omit it when using --only")
    parser.add_argument("--only", action="append", choices=tuple(LANES), metavar="LANE",
                        help="run one workflow lane; repeat to run several")
    parser.add_argument("--list-lanes", action="store_true",
                        help="print the available lanes and exit")
    parser.add_argument("--android", action="store_true", help="include Android host checks")
    parser.add_argument("--macos", action="store_true", help="include macOS hosted checks")
    parser.add_argument("--serial", help="adb serial for device lanes")
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
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/reports/verification",
                        help="report root; each invocation creates an isolated run directory")
    args = parser.parse_args(argv)

    if args.list_lanes:
        for name, suites in LANES.items():
            print("%s: %s" % (name, ", ".join(suites)))
        return 0

    if args.only and args.mode:
        parser.error("mode and --only are mutually exclusive")
    if not args.only and not args.mode:
        parser.error("choose a mode (fast, device, all) or at least one --only LANE")
    if args.only and (args.android or args.macos or args.skip_rust):
        parser.error("--android, --macos and --skip-rust only modify a mode; "
                     "do not combine them with --only")

    if args.only:
        requested = list(dict.fromkeys(args.only))
        selected = {name: False for name in SUITE_ORDER}
        for lane in requested:
            for name in LANES[lane]:
                selected[name] = True
        mode = "only"
    else:
        # Bare fast retains both local platform suites; CI selects one lane explicitly.
        host_checks = args.mode in ("fast", "all")
        android = host_checks and (args.android or not args.macos)
        macos = host_checks and (args.macos or not args.android)
        device = args.mode in ("device", "all")
        selected = {name: False for name in SUITE_ORDER}
        selected.update({
            "structure": host_checks,
            "vectors": host_checks,
            "python": host_checks,
            "rust": host_checks and not args.skip_rust,
            "android": android,
            "macos": macos,
            "connected": device,
            "interchange": device,
        })
        requested = [lane for lane, suites in LANES.items()
                     if any(selected[name] for name in suites)]
        mode = args.mode

    device_selected = selected["connected"] or selected["interchange"]
    if args.allow_no_device and not device_selected:
        parser.error("--allow-no-device requires the connected or interchange lane")
    if args.serial and not device_selected:
        parser.error("--serial requires the connected or interchange lane")
    if args.session_mac_binary and not selected["interchange"]:
        parser.error("--session-mac-binary requires the interchange lane")

    summary = {
        "mode": mode,
        "requested_lanes": requested,
        "status": "running",
        "suites": {name: {"status": "pending" if selected[name] else "not_selected"}
                   for name in SUITE_ORDER},
        "commands": [],
        "errors": [],
    }
    if mode in ("fast", "all") and args.skip_rust:
        # An explicit omission is recorded separately from a suite that was never selected.
        summary["suites"]["rust"].update(status="not_executed", reason="--skip-rust")
    if selected["android"]:
        summary["suites"]["android"]["reports"] = [
            str(ANDROID / "app/build/test-results/testDebugUnitTest"),
            str(ANDROID / "app/build/reports"),
        ]
    artifacts = None
    active = None
    started = time.monotonic()
    documented_android = () if args.strict_skips else DOCUMENTED_ANDROID_SKIPS
    documented_macos = () if args.strict_skips else DOCUMENTED_MACOS_SKIPS

    try:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        # Separate runs retain their own evidence, including when another invocation fails.
        artifacts = Path(tempfile.mkdtemp(prefix="run-", dir=args.output_dir)).resolve()
        print("Verification artifacts: " + str(artifacts), flush=True)
        write_json(artifacts / "summary.json", summary)
        if (selected["macos"] or selected["interchange"]) and platform.system() != "Darwin":
            raise GateError("macOS hosted and interchange checks require macOS; "
                            "use --only android or --only contracts on Linux")
        env = toolchain_env(android=selected["android"] or selected["connected"],
                            macos=selected["macos"] or selected["interchange"],
                            require_xcode=selected["macos"])

        def execute(name, function):
            # Persist suite progress around execution so an unfinished run cannot resemble a pass.
            nonlocal active
            active = name
            row = summary["suites"][name]
            row["status"] = "running"
            write_json(artifacts / "summary.json", summary)
            suite_started = time.monotonic()
            try:
                result = function()
            finally:
                row["elapsed_seconds"] = round(time.monotonic() - suite_started, 3)
            row["status"] = "passed"
            if isinstance(result, NotExecuted):
                row.update(status="not_executed", reason=result.reason)
            elif isinstance(result, dict):
                row.update(result)
            elif isinstance(result, tuple):
                # Native validators return accepted passes and the reviewed skip count.
                row.update(passed=result[0], documented_skips=result[1])
            elif isinstance(result, int):
                row["checks" if name == "vectors" else "passed"] = result
            write_json(artifacts / "summary.json", summary)
            active = None

        if selected["ci-integrity"]:
            execute("ci-integrity", lambda: run_ci_integrity(env, artifacts))
        if selected["structure"]:
            execute("structure", lambda: run_structure(artifacts))
        if selected["vectors"]:
            active = "vectors"
            interpreter = vector_interpreter(args.vector_python)
            execute("vectors", lambda: run_vector_checks(interpreter, artifacts))
        if selected["python"]:
            execute("python", lambda: run_python_meta_tests(env, artifacts))
        if selected["rust"]:
            execute("rust", lambda: run_rust(env, artifacts))
        if selected["android"]:
            execute("android", lambda: run_android_jvm(env, artifacts))
        if selected["macos"]:
            execute("macos", lambda: run_macos_with_skips(env, artifacts, documented_macos, args.allow_skip))
        # Preserve the legacy device order: native interchange first, then the broad connected suite.
        if selected["interchange"]:
            execute("interchange", lambda: run_interchange_checks(args, env, artifacts))
        if selected["connected"]:
            execute("connected", lambda: run_connected_checks(args, env, artifacts, documented_android))
        summary["status"] = "passed_with_omissions" if any(
            row["status"] == "not_executed" for row in summary["suites"].values()) else "passed"
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        summary["errors"].append(str(error))
        summary["status"] = "failed"
        if active:
            summary["suites"][active]["status"] = "failed"
        workflow_error(error)
    except KeyboardInterrupt:
        summary["errors"].append("Verification interrupted")
        summary["status"] = "failed"
        if active:
            summary["suites"][active]["status"] = "failed"
    finally:
        summary["elapsed_seconds"] = round(time.monotonic() - started, 3)
        # Fail-fast execution leaves later suites unexecuted, not implicitly successful.
        for row in summary["suites"].values():
            if row["status"] == "pending":
                row.update(status="not_executed", reason="Verification stopped before this suite")
        if artifacts:
            try:
                summary["commands"] = [json.loads(path.read_text(encoding="utf-8"))
                                       for path in sorted(artifacts.glob("*.command.json"))]
            except (OSError, ValueError) as error:
                summary["status"] = "failed"
                summary["errors"].append("Cannot read verification diagnostics: " + str(error))
                workflow_error(error)
            try:
                (artifacts / "summary.md").write_text(
                    markdown_summary(summary), encoding="utf-8")
            except OSError as error:
                summary["status"] = "failed"
                summary["errors"].append("Cannot save verification summary: " + str(error))
                workflow_error(error)
            try:
                # A successful command cannot make an unreadable or unwritable final report green.
                write_json(artifacts / "summary.json", summary)
            except (OSError, ValueError) as error:
                summary["status"] = "failed"
                summary["errors"].append("Cannot save verification diagnostics: " + str(error))
                workflow_error(error)
        append_step_summary(summary)

    if summary["status"] == "failed":
        print("\nVERIFICATION FAILED:", file=sys.stderr)
        for error in summary["errors"]:
            print("\n".join("| " + line for line in error.splitlines()), file=sys.stderr)
        print("Artifacts: " + str(artifacts), file=sys.stderr)
        return 1
    print("\nVERIFICATION PASSED" + (" (omissions recorded)" if summary["status"] == "passed_with_omissions" else ""))
    print("Artifacts: " + str(artifacts))
    return 0


def read_xcode_version(log_path):
    """Returns the toolchain identity that actually compiled the app."""
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return lines[0].strip() if lines else ""


def run_macos_with_skips(env, artifacts, documented, extra):
    # The native library is a link input, not an app test result. Rebuild it from
    # source so a stale archive cannot make a broken bridge look green.
    library = MACOS / "build" / "native" / "libanice_pairing.a"
    toolchain = run_step("macOS toolchain", ["xcodebuild", "-version"], artifacts, env=env)
    if library.exists():
        library.unlink()
    run_step(
        "macOS native pairing bridge",
        [sys.executable, SCRIPTS / "build-pairing-native.py", "macos"],
        artifacts, env=env, timeout=1200,
    )
    if not library.is_file():
        raise GateError("macOS native pairing build produced no libanice_pairing.a")

    # Keep generated build products out of the uploaded evidence directory, and
    # ensure temporary derived data is cleaned up even if compilation or tests fail.
    derived = Path(tempfile.mkdtemp(prefix="anice-macos-derived-"))
    try:
        run_step(
            "macOS Release build",
            [
                "xcodebuild", "-project", "aniCe.xcodeproj", "-scheme", "aniCe",
                "-configuration", "Release", "-derivedDataPath", str(derived),
                "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-",
                "build",
            ],
            artifacts, cwd=MACOS, env=env, timeout=1800,
        )
        app_bundle = derived / "Build" / "Products" / "Release" / "aniCe.app"
        app_binary = app_bundle / "Contents" / "MacOS" / "aniCe"
        if not app_binary.is_file():
            raise GateError("macOS Release build produced no app binary at " + str(app_binary))

        binaries = (
            ("macOS architecture verification", app_binary),
            ("macOS update helper architecture", app_bundle / "Contents/Helpers/aniCeUpdateHelper"),
            ("macOS playback adapter architecture", app_bundle / "Contents/Resources/NowPlaying/libaniCeNowPlaying.dylib"),
        )
        for label, binary in binaries:
            if not binary.is_file():
                raise GateError("macOS Release build produced no binary at " + str(binary))
            arch_log = run_step(label, ["lipo", "-archs", str(binary)], artifacts, env=env)
            architectures = arch_log.read_text(encoding="utf-8").split()
            if architectures != ["arm64"]:
                raise GateError(str(binary) + " must contain exactly arm64; reported: " + " ".join(architectures))

        run_step(
            "macOS codesign verification",
            ["codesign", "--verify", "--deep", "--strict", str(app_bundle)],
            artifacts, env=env,
        )

        bundle = artifacts / "macos.xcresult"
        if bundle.exists():
            shutil.rmtree(bundle)
        log = run_step(
            "macOS hosted tests",
            [
                "xcodebuild", "-project", "aniCe.xcodeproj", "-scheme", "aniCe",
                "-configuration", "Debug", "-derivedDataPath", str(derived),
                "-destination", "platform=macOS", "-resultBundlePath", str(bundle),
                "CODE_SIGN_IDENTITY=-", "test",
            ],
            artifacts, cwd=MACOS, env=env, timeout=2400,
        )
        results = parse_xcode_results(bundle, log, env=env)
        write_json(artifacts / "macos-tests.json", [asdict(result) for result in results])
        passed, skipped = validate_results(
            results, "macOS hosted", MINIMUMS["macos"],
            documented=documented, extra=extra,
        )
        # Record the compiler and verified architecture.
        return {
            "passed": passed,
            "documented_skips": skipped,
            "xcode": read_xcode_version(toolchain),
            "arch": "arm64",
        }
    finally:
        shutil.rmtree(derived, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
