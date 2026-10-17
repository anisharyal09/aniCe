#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial checks for the aggregate verification gate (no device required)."""
import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("verify_suite", Path(__file__).with_name("verify-suite.py"))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


def junit(path, body):
    path.write_text('<testsuite name="pkg.Test" %s>%s</testsuite>' % (body[0], body[1]))
    return suite.parse_junit_files([path])


class JunitGateTests(unittest.TestCase):
    def test_complete_passing_report_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "TEST-pass.xml"
            results = junit(
                report,
                ('tests="2" failures="0" errors="0" skipped="0"',
                 '<testcase classname="pkg.Test" name="a"/>'
                 '<testcase classname="pkg.Test" name="b"/>'),
            )
            self.assertEqual(len(results), 2)
            suite.validate_results(results, "fake", minimum=2)

    def test_skipped_test_is_rejected_even_when_the_process_exits_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "TEST-skip.xml"
            results = junit(
                report,
                ('tests="2" failures="0" errors="0" skipped="1"',
                 '<testcase classname="pkg.Test" name="runs"/>'
                 '<testcase classname="pkg.Test" name="skips"><skipped/></testcase>'),
            )
            with self.assertRaises(suite.GateError):
                suite.validate_results(results, "fake", minimum=2)
            # The same report is accepted only with an explicit, reviewed pattern.
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                suite.validate_results(
                    results, "fake", minimum=2,
                    extra=["Test#skips"],
                )
            self.assertIn("documented skip: pkg.Test#skips", output.getvalue())

    def test_zero_test_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "TEST-empty.xml"
            results = junit(report, ('tests="0" failures="0" errors="0" skipped="0"', ""))
            self.assertEqual(results, [])
            with self.assertRaises(suite.GateError):
                suite.validate_results(results, "fake", minimum=1)

    def test_crash_error_and_ignored_test_are_rejected(self):
        cases = {
            "error": '<testcase classname="pkg.Test" name="crash"><error message="Process crashed"/></testcase>',
            "failure": '<testcase classname="pkg.Test" name="failed"><failure message="assert"/></testcase>',
            "ignored": '<testcase classname="pkg.Test" name="ignored"><ignored/></testcase>',
        }
        for name, body in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                report = Path(directory) / "TEST-case.xml"
                results = junit(report, ('tests="1"', body))
                with self.assertRaises(suite.GateError):
                    suite.validate_results(results, "fake", minimum=1)

    def test_truncated_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "TEST-truncated.xml"
            with self.assertRaises(suite.GateError):
                junit(
                    report,
                    ('tests="3"',
                     '<testcase classname="pkg.Test" name="a"/>'
                     '<testcase classname="pkg.Test" name="b"/>'),
                )

    def test_suite_level_runner_error_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "TEST-runner.xml"
            report.write_text(
                '<testsuite name="pkg.Test" tests="0"><error message="Runner crashed"/></testsuite>'
            )
            results = suite.parse_junit_files([report])
            self.assertTrue(any(result.outcome == "error" for result in results))
            with self.assertRaises(suite.GateError):
                suite.validate_results(results, "fake", minimum=1)


XCODE_LOG = """\
Test Case '-[aniCeTests.ExampleTests testRuns]' passed (0.001 seconds).
Test Case '-[aniCeTests.ExampleTests testManual]' skipped (0.001 seconds).
"""


class XcodeGateTests(unittest.TestCase):
    def test_log_parser_and_documented_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "xcode.log"
            log.write_text(XCODE_LOG)
            results = suite.parse_xcode_log(log)
            self.assertEqual(
                [(result.identifier, result.outcome) for result in results],
                [("aniCeTests.ExampleTests#testRuns", "passed"),
                 ("aniCeTests.ExampleTests#testManual", "skipped")],
            )
            with self.assertRaises(suite.GateError):
                suite.validate_results(results, "macOS", minimum=2)
            suite.validate_results(
                results, "macOS", minimum=2,
                documented={"ExampleTests#testManual"},
            )

    def test_failed_case_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "xcode.log"
            log.write_text("Test Case '-[aniCeTests.ExampleTests testBad]' failed (0.001 seconds).\n")
            results = suite.parse_xcode_log(log)
            with self.assertRaises(suite.GateError):
                suite.validate_results(results, "macOS", minimum=1)


class RunnerGateTests(unittest.TestCase):
    def cargo(self, text):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "cargo.log"
            log.write_text(text)
            return suite.cargo_results(log)

    def test_rust_all_executed_passes(self):
        self.assertEqual(
            self.cargo("test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"),
            4,
        )

    def test_rust_ignored_filtered_failed_and_zero_are_rejected(self):
        cases = {
            "ignored": "test result: ok. 3 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out\n",
            "filtered": "test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out\n",
            "failed": "test result: FAILED. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out\n",
            "zero": "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n",
            "missing": "Compiling pairing v0.1.0\nFinished\n",
        }
        for name, text in cases.items():
            with self.subTest(case=name), self.assertRaises(suite.GateError):
                self.cargo(text)

    def unittest_log(self, text):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "python.log"
            log.write_text(text)
            return suite.unittest_results(log)

    def test_python_all_executed_passes(self):
        self.assertEqual(
            self.unittest_log("Ran 18 tests in 0.120s\n\nOK\n"),
            18,
        )

    def test_python_skips_failures_and_zero_are_rejected(self):
        cases = {
            "skipped": "Ran 18 tests in 0.120s\n\nOK (skipped=1)\n",
            "failed": "Ran 18 tests in 0.120s\n\nFAILED (failures=1)\n",
            "zero": "Ran 0 tests in 0.000s\n\nOK\n",
            "missing": "no summary\n",
        }
        for name, text in cases.items():
            with self.subTest(case=name), self.assertRaises(suite.GateError):
                self.unittest_log(text)


if __name__ == "__main__":
    unittest.main()
