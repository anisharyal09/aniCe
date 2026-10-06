#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial checks for the native harness's success gate (no device required)."""
import importlib.util
import base64
import json
import sys
import tempfile
from pathlib import Path
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("interchange", Path(__file__).with_name("verify-identity-interchange.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

PASS = "INSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_STATUS_CODE: 0\nOK (1 test)\nINSTRUMENTATION_CODE: -1\n"


class InstrumentationGateTests(unittest.TestCase):
    def test_completed_test_passes(self):
        harness.require_instrumentation_pass(PASS)

    def test_false_pass_outputs_are_rejected(self):
        cases = {
            "skipped": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -3"),
            "ignored": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -4"),
            "assertion_failed": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -2"),
            "crashed": PASS.replace("STATUS_CODE: 0", "STATUS_CODE: -1"),
            "no_test": "OK (1 test)\nINSTRUMENTATION_CODE: -1\n",
            "zero_tests": PASS.replace("OK (1 test)", "OK (0 tests)"),
            "missing_finish": PASS.replace("INSTRUMENTATION_CODE: -1\n", ""),
            "failed_finish": PASS.replace("INSTRUMENTATION_CODE: -1", "INSTRUMENTATION_CODE: 0"),
            "extra_test": PASS + "INSTRUMENTATION_STATUS_CODE: 0\n",
            "failure_marker": PASS + "FAILURES!!!\n",
            "runner_error": PASS + "INSTRUMENTATION_FAILED\n",
            "short_error": PASS + "INSTRUMENTATION_RESULT: shortMsg=Process crashed\n",
        }
        for name, log in cases.items():
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                harness.require_instrumentation_pass(log)


class IndependentVerifierTests(unittest.TestCase):
    def test_shared_signatures_pass_and_altered_messages_fail(self):
        vectors = json.loads((harness.ROOT / "protocol/test-vectors/identity-vectors.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            bundle_path = output / "vector.json"
            for vector in vectors["valid"]:
                with self.subTest(vector=vector["name"]):
                    bundle = {key: vector[key] for key in ("identity", "messageBase64", "signatureBase64")}
                    bundle_path.write_text(json.dumps(bundle))
                    harness.verify_with_openssl(bundle_path, output)
                    bundle["messageBase64"] = base64.b64encode(
                        base64.b64decode(bundle["messageBase64"]) + bytes([0])).decode()
                    bundle_path.write_text(json.dumps(bundle))
                    with self.assertRaises(RuntimeError):
                        harness.verify_with_openssl(bundle_path, output)


if __name__ == "__main__":
    unittest.main()
