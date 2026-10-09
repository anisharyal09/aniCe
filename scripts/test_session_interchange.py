#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial checks for session-runner completion, evidence and cleanup gates."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "session_interchange", Path(__file__).with_name("verify-session-interchange.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


def event(name, current, code):
    return (
        f"INSTRUMENTATION_STATUS: class={harness.TEST_CLASS}\n"
        f"INSTRUMENTATION_STATUS: current={current}\n"
        "INSTRUMENTATION_STATUS: numtests=2\n"
        f"INSTRUMENTATION_STATUS: test={name}\n"
        f"INSTRUMENTATION_STATUS_CODE: {code}\n"
    )


FIRST = event("protectedKeyInterchange", 1, 1) + event("protectedKeyInterchange", 1, 0)
SECOND = event("nativeProviderConformance", 2, 1) + event("nativeProviderConformance", 2, 0)
RESULT = "OK (2 tests)\nINSTRUMENTATION_CODE: -1\n"
PASS = FIRST + SECOND + RESULT


class SessionInstrumentationGateTests(unittest.TestCase):
    def test_both_completed_tests_pass_in_either_order(self):
        harness.require_instrumentation_pass(PASS)
        reverse = PASS.replace("protectedKeyInterchange", "temporaryName")
        reverse = reverse.replace("nativeProviderConformance", "protectedKeyInterchange")
        harness.require_instrumentation_pass(reverse.replace("temporaryName", "nativeProviderConformance"))

    def test_false_success_outputs_fail(self):
        cases = {
            "skip": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -3", 1),
            "ignore": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -4", 1),
            "assertion": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -2", 1),
            "crash": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -1", 1),
            "no_tests": RESULT,
            "missing_test": FIRST + RESULT,
            "missing_end": PASS.replace(SECOND, event("nativeProviderConformance", 2, 1)),
            "zero_tests": PASS.replace("OK (2 tests)", "OK (0 tests)"),
            "extra_test": PASS + event("unexpected", 3, 0),
            "wrong_class": PASS.replace(harness.TEST_CLASS, "OtherTest"),
            "wrong_name": PASS.replace("nativeProviderConformance", "OtherTest"),
            "duplicate_name": PASS.replace("nativeProviderConformance", "protectedKeyInterchange"),
            "wrong_inventory": PASS.replace("numtests=2", "numtests=3"),
            "wrong_current": PASS.replace("current=2", "current=1"),
            "missing_result": PASS.replace("INSTRUMENTATION_CODE: -1\n", ""),
            "failed_result": PASS.replace("INSTRUMENTATION_CODE: -1", "INSTRUMENTATION_CODE: 0"),
            "extra_result": PASS + "INSTRUMENTATION_CODE: -1\n",
            "failure_marker": PASS + "FAILURES!!!\n",
            "runner_error": PASS + "INSTRUMENTATION_FAILED\n",
            "runner_crash": PASS + "INSTRUMENTATION_RESULT: shortMsg=Process crashed\n",
        }
        self.assertGreaterEqual(len(cases), 15)
        for name, output in cases.items():
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                harness.require_instrumentation_pass(output)


class SessionEvidenceTests(unittest.TestCase):
    def exchange(self, fail_cleanup, control_agreement=True, renewal_agreement=True):
        run = "00000000-0000-4000-8000-000000000001"
        remote = f"/storage/emulated/0/Android/data/io.github.anisharyal09.anice/files/session-interchange-{run}"
        cleanup_reached = False

        def popen(*_, **kwargs):
            if hasattr(kwargs["stdout"], "write"):
                kwargs["stdout"].write(PASS)
            return SimpleNamespace(stdin=io.StringIO(), returncode=0,
                                   poll=lambda: 0, wait=lambda **_: 0)

        def command(_, *parts):
            nonlocal cleanup_reached
            if parts[:3] == ("shell", "rm", "-rf"):
                cleanup_reached = True
                if fail_cleanup:
                    raise RuntimeError("Injected exchange-file cleanup failure")
            return "36"

        with tempfile.TemporaryDirectory() as directory:
            args = ["verify-session-interchange.py", "--serial", "test-device",
                    "--mac-binary", "/unused", "--output", directory]
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch("sys.argv", args))
                stack.enter_context(patch.object(harness.uuid, "uuid4", return_value=run))
                stack.enter_context(patch.object(harness.subprocess, "Popen", side_effect=popen))
                stack.enter_context(patch.object(harness, "command", side_effect=command))
                stack.enter_context(patch.object(harness, "receive", side_effect=[
                    {"identity": {}}, {"message2Hex": "00"},
                    {"message4Hex": "00", "exportDigestHex": "test"}, {"readyAckHex":"00"},
                    {"helloReplyHex":"00"}, {"pingReplyHex":"00"}, {"serverDataHex":"00"}, {"cleanup": True}]))
                stack.enter_context(patch.object(harness, "wait_file", side_effect=[
                    {"directory": remote}, {"message1Hex": "00"}, {"message3Hex": "00"},
                    {"readyHex":"00"},{"helloHex":"00"},{"pingHex":"00"},{"clientDataHex":"00"},{"closeHex":"00"},
                    {"stage": "COMPLETE", "exportDigestHex": "test", "recordAgreement":True,
                     "controlAgreement":control_agreement,"renewalAgreement":renewal_agreement,"bidirectionalBytes":4000}]))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                if fail_cleanup:
                    with self.assertRaisesRegex(RuntimeError, "Injected exchange-file cleanup failure"):
                        harness.main()
                elif not renewal_agreement:
                    with self.assertRaisesRegex(AssertionError, "Native record/readiness agreement failed"):
                        harness.main()
                elif not control_agreement:
                    with self.assertRaisesRegex(AssertionError, "Native HELLO/PING control agreement failed"):
                        harness.main()
                else:
                    harness.main()
            self.assertTrue(cleanup_reached, "Cleanup fault boundary was not reached")
            outputs = list(Path(directory).glob("*/result.json"))
            if fail_cleanup or not control_agreement or not renewal_agreement:
                self.assertEqual(outputs, [], "A failed run left a durable success report")
            else:
                self.assertEqual(len(outputs), 1)
                report = json.loads(outputs[0].read_text())
                self.assertEqual(report["manualAcceptance"], "pending")
                self.assertEqual(report["evidenceKind"], "automated-native-interchange")
                self.assertFalse(report["bleVerified"])
                self.assertTrue(report["controlAgreement"])

    def test_cleanup_failure_does_not_persist_success(self):
        self.exchange(fail_cleanup=True)

    def test_success_report_distinguishes_manual_acceptance(self):
        self.exchange(fail_cleanup=False)

    def test_missing_renewal_agreement_does_not_persist_success(self):
        self.exchange(fail_cleanup=False, renewal_agreement=False)

    def test_missing_control_agreement_does_not_persist_success(self):
        self.exchange(fail_cleanup=False, control_agreement=False)


if __name__ == "__main__":
    unittest.main()
