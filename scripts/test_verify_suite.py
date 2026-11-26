#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial checks for the aggregate verification gate (no device required)."""
import contextlib
import ast
import importlib.util
import io
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("verify_suite", Path(__file__).with_name("verify-suite.py"))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


def junit(path, body):
    path.write_text('<testsuite name="pkg.Test" %s>%s</testsuite>' % (body[0], body[1]))
    return suite.parse_junit_files([path])


class JunitGateTests(unittest.TestCase):
    # Small synthetic XML reports isolate the acceptance rules from Android and Gradle.
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
                    results, "fake", minimum=1,
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

    def test_nested_report_totals_cannot_hide_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'nested.xml'
            cases = '<testcase name="a"/><testcase name="b"/>'
            for tag, declared in (('testsuite', '3'), ('testsuite', 'bad'), ('testsuites', '3')):
                for root_total in ('', ' tests="2"'):
                    with self.subTest(tag=tag, declared=declared, root_total=root_total):
                        report.write_text('<testsuites%s><%s tests="%s">%s</%s></testsuites>' %
                                          (root_total, tag, declared, cases, tag))
                        with self.assertRaises(suite.GateError):
                            suite.parse_junit_files([report])
            report.write_text('<testsuites><testsuite tests="2">' + cases + '</testsuite></testsuites>')
            self.assertEqual(len(suite.parse_junit_files([report])), 2)

    def test_failure_cannot_be_overridden_by_a_documented_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'mixed.xml'
            for failure in ('<failure message="assertion"/>', '<error message="crash"/>'):
                for skipped in ('<skipped/>', '<ignored/>', '<disabled/>'):
                    for children in (failure + skipped, skipped + failure):
                        with self.subTest(children=children):
                            results = junit(report, ('tests="2"',
                                '<testcase classname="pkg.Test" name="good"/>'
                                '<testcase classname="pkg.Test" name="mixed">' + children + '</testcase>'))
                            with self.assertRaises(suite.GateError):
                                suite.validate_results(results, 'mixed', 2, documented={'Test#mixed'})

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


    def test_declared_outcomes_cannot_hide_missing_failure_or_skip_details(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "outcomes.xml"
            for attribute in ("failures", "errors", "skipped"):
                for wrapper in (False, True):
                    with self.subTest(attribute=attribute, wrapper=wrapper):
                        body = '<testsuite tests="1"><testcase name="a"/></testsuite>'
                        if wrapper:
                            text = f'<testsuites {attribute}="1">{body}</testsuites>'
                        else:
                            text = body.replace('tests="1"', f'tests="1" {attribute}="1"')
                        report.write_text(text)
                        with self.assertRaisesRegex(suite.GateError, "report is incomplete"):
                            suite.parse_junit_files([report])

    def test_duplicate_results_and_skips_cannot_satisfy_the_pass_floor(self):
        passed = suite.TestResult("Test", "runs", "passed")
        skipped = suite.TestResult("Test", "manual", "skipped")
        with self.assertRaisesRegex(suite.GateError, "duplicate"):
            suite.validate_results([passed, passed], "duplicate", 2)
        with self.assertRaisesRegex(suite.GateError, "skipped tests do not count"):
            suite.validate_results([passed, skipped], "shrunk", 2, documented={"Test#manual"})
        with self.assertRaisesRegex(suite.GateError, "unknown test outcome"):
            suite.validate_results([suite.TestResult("Test", "unknown", "unknown")], "unknown", 1)

    def test_documented_comparison_fixture_skip_is_visible_and_strict_mode_rejects_it(self):
        executed = suite.TestResult("io.github.anisharyal09.anice.NativeTest", "runs", "passed")
        fixture = suite.TestResult(
            "io.github.anisharyal09.anice.features.pairing.ComparisonPresentationTest",
            "globalAndAddDeviceSurfacesRenderTheSameLiveCodeAcrossPhaseChanges", "skipped",
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(suite.validate_results(
                [executed, fixture], "physical", 1, documented=suite.DOCUMENTED_ANDROID_SKIPS
            ), (1, 1))
        self.assertIn("documented skip: " + fixture.identifier, output.getvalue())
        with self.assertRaises(suite.GateError):
            suite.validate_results([executed, fixture], "strict", 1, documented=())
        self.assertNotIn(
            "ComparisonPresentationTest#everyPairingMethodHandsOffItsNativeCandidateOnlyOnceAfterTrustIsSaved",
            suite.DOCUMENTED_ANDROID_SKIPS,
        )


XCODE_LOG = """\
Test Case '-[aniCeTests.ExampleTests testRuns]' passed (0.001 seconds).
Test Case '-[aniCeTests.ExampleTests testManual]' skipped (0.001 seconds).
"""


class XcodeGateTests(unittest.TestCase):
    # Reported totals must agree with individual outcomes, even when the process reports success.
    def test_result_bundle_disagreement_never_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'xcode.log'
            log.write_text(XCODE_LOG)
            for summary in ({'totalTestCount': 0}, {'totalTestCount': 3},
                            {'totalTestCount': 2, 'skippedTests': 0},
                            {'totalTestCount': 2, 'failedTests': 1}):
                with self.subTest(summary=summary), patch.object(suite, '_xcresult_json', return_value=summary):
                    with self.assertRaises(suite.GateError):
                        suite.parse_xcode_results(Path(directory) / 'tests.xcresult', log)

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
                results, "macOS", minimum=1,
                documented={"ExampleTests#testManual"},
            )

    def test_failed_case_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "xcode.log"
            log.write_text("Test Case '-[aniCeTests.ExampleTests testBad]' failed (0.001 seconds).\n")
            results = suite.parse_xcode_log(log)
            with self.assertRaises(suite.GateError):
                suite.validate_results(results, "macOS", minimum=1)

    def test_xcresult_probe_uses_the_selected_toolchain(self):
        environment = {"DEVELOPER_DIR": "/pinned/Xcode.app/Contents/Developer"}
        with patch.object(suite.subprocess, "run") as probe:
            probe.return_value = SimpleNamespace(returncode=0, stdout="{}")
            self.assertEqual(
                suite._xcresult_json(Path("tests.xcresult"), "summary", env=environment),
                {},
            )
        self.assertEqual(probe.call_args.kwargs["env"], environment)


class RunnerGateTests(unittest.TestCase):
    # Crafted summaries test count floors and skipped/filtered cases without rerunning Rust or Python.
    def cargo(self, text):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "cargo.log"
            log.write_text(text)
            return suite.cargo_results(log)

    def test_rust_all_executed_passes(self):
        count = suite.MINIMUMS["rust"]
        self.assertEqual(
            self.cargo(f"test result: ok. {count} passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"),
            count,
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
        count = suite.MINIMUMS["python"]
        self.assertEqual(
            self.unittest_log(f"Ran {count} tests in 0.120s\n\nOK\n"),
            count,
        )

    def test_python_skips_failures_and_zero_are_rejected(self):
        count = suite.MINIMUMS["python"]
        cases = {
            "skipped": f"Ran {count} tests in 0.120s\n\nOK (skipped=1)\n",
            "failed": f"Ran {count} tests in 0.120s\n\nFAILED (failures=1)\n",
            "zero": "Ran 0 tests in 0.000s\n\nOK\n",
            "missing": "no summary\n",
            "truncated": f"Ran {count} tests in 0.120s\n",
            "expected_failures": f"Ran {count} tests in 0.120s\n\nOK (expected failures=1)\n",
            "earlier_ok": f"OK\nRan {count} tests in 0.120s\n",
            "multiple_runs": f"Ran {count} tests in 0.120s\nOK\nRan 1 test in 0.120s\nOK\n",
            "below_floor": f"Ran {count - 1} tests in 0.120s\n\nOK\n",
        }
        for name, text in cases.items():
            with self.subTest(case=name), self.assertRaises(suite.GateError):
                self.unittest_log(text)


class ProcessDiagnosticsTests(unittest.TestCase):
    # Real child processes exercise exit codes, timeouts and saved logs independently of test parsers.
    def test_nonzero_exit_cannot_be_overridden_by_success_text(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            artifacts = Path(directory)
            with self.assertRaisesRegex(suite.GateError, 'exit 17'):
                suite.run_step('Dishonest runner', [sys.executable, '-c',
                               'print("VERIFICATION PASSED"); raise SystemExit(17)'], artifacts)
            record = json.loads((artifacts / 'dishonest-runner.command.json').read_text())
            self.assertEqual((record['status'], record['exit_code']), ('failed', 17))
            self.assertIn('VERIFICATION PASSED', Path(record['log']).read_text())

    def test_missing_executable_and_timeout_leave_failure_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            artifacts = Path(directory)
            for label, command, message in (
                ('Missing', [artifacts / 'absent-tool'], 'could not run'),
                ('Timeout', [sys.executable, '-c', 'import time; print("started", flush=True); time.sleep(30)'], 'timed out'),
            ):
                with self.subTest(label=label), self.assertRaisesRegex(suite.GateError, message):
                    suite.run_step(label, command, artifacts, timeout=0.3)
                record = json.loads((artifacts / (label.lower() + '.command.json')).read_text())
                self.assertEqual(record['status'], 'failed')
                self.assertIsNone(record['exit_code'])
                self.assertTrue(Path(record['log']).is_file())
            # A busy runner may time out during interpreter startup, leaving a valid empty log.

    def test_diagnostic_write_failure_retains_the_command_failure(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            # Allow initial recording, then revoke writes when the failed command is recorded.
            with patch.object(suite, 'write_json', side_effect=[None, PermissionError('read-only reports')]):
                with self.assertRaisesRegex(suite.GateError, 'exit 17;.*Cannot save command diagnostics'):
                    suite.run_step('Failure', [sys.executable, '-c', 'raise SystemExit(17)'], Path(directory))

    def test_timeout_retires_descendants_not_just_the_launcher(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            artifacts = Path(directory)
            code = (
                "import subprocess, sys, time\n"
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import pathlib,sys,time; time.sleep(1); pathlib.Path(sys.argv[1]).write_text(\"orphan\")', "
                "sys.argv[1]])\n"
                "time.sleep(30)\n"
            )
            marker = artifacts / "orphan.txt"
            with self.assertRaisesRegex(suite.GateError, 'timed out'):
                suite.run_step('Child tree', [sys.executable, '-c', code, marker], artifacts, timeout=0.3)
            # A real child wait gives an escaped descendant time to write, without polling it.
            suite.subprocess.run([sys.executable, '-c', 'import time; time.sleep(1.2)'], check=True, timeout=5)
            self.assertFalse(marker.exists())
            record = json.loads((artifacts / 'child-tree.command.json').read_text())
            self.assertEqual(record['status'], 'failed')

    def test_termination_records_failure_and_retires_the_active_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            code = (
                "import importlib.util,os,signal,sys,threading\n"
                "spec=importlib.util.spec_from_file_location('termination_gate',sys.argv[1])\n"
                "gate=importlib.util.module_from_spec(spec);sys.modules[spec.name]=gate;spec.loader.exec_module(gate)\n"
                "gate.run_structure=lambda output: gate.run_step('Terminated runner',"
                "[sys.executable,'-c','import time; time.sleep(30)'],output)\n"
                "timer=threading.Timer(0.3,lambda:os.kill(os.getpid(),signal.SIGTERM));timer.start()\n"
                "sys.exit(gate.main(['--only','contracts','--output-dir',sys.argv[2]]))\n"
            )
            completed = suite.subprocess.run(
                [sys.executable, '-c', code, suite.__file__, artifacts],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            reports = list(artifacts.glob('run-*/summary.json'))
            self.assertEqual(len(reports), 1)
            report = json.loads(reports[0].read_text())
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['suites']['structure']['status'], 'failed')
            self.assertIn('interrupted', report['errors'][0])

    def test_annotations_escape_messages_and_source_properties(self):
        output = io.StringIO()
        # The apparent notice must remain inside one escaped error annotation.
        error = suite.GateError('bad%\r\n::notice::injected', file='a,b:c.py', line=7)
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), contextlib.redirect_stderr(output):
            suite.workflow_error(error)
        self.assertEqual(output.getvalue(), '::error file=a%2Cb%3Ac.py,line=7::bad%25%0D%0A::notice::injected\n')
        output = io.StringIO()
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), contextlib.redirect_stderr(output):
            suite.workflow_error(error)
        self.assertEqual(output.getvalue(), '')

    def test_log_tail_cannot_inject_workflow_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'runner.log'
            log.write_text('::error::injected\nnormal\r::notice::also injected\n')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                suite.print_tail(log)
            self.assertTrue(all(line.startswith('| ') for line in output.getvalue().splitlines()))


class AggregateGateTests(unittest.TestCase):
    # Mock suite execution to test orchestration and reporting without requiring platform toolchains.
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def invoke(self, arguments=(), overrides=None):
        before = set(self.root.glob('run-*'))
        # These counts are synthetic return values; they do not represent executed app tests.
        defaults = {
            'toolchain_env': {'PATH': '/mock/bin'},
            'run_ci_integrity': {'actionlint': 'passed', 'policy_tests': 12},
            'run_structure': None, 'vector_interpreter': sys.executable,
            'run_vector_checks': {'checks': len(suite.VECTOR_CHECKS), 'oracle_tests': 5},
            'run_python_meta_tests': 30, 'run_rust': 4,
            'run_android_jvm': (300, 0),
            'run_macos_with_skips': {'passed': 300, 'documented_skips': 3,
                                     'xcode': 'Xcode 26.3', 'arch': 'arm64'},
            'run_connected_checks': (10, 0),
            'run_interchange_checks': {'harnesses': 3},
        }
        mocks = {}
        with contextlib.ExitStack() as stack:
            for name, result in defaults.items():
                value = (overrides or {}).get(name, result)
                options = {'side_effect': value} if isinstance(value, BaseException) else {'return_value': value}
                mocks[name] = stack.enter_context(patch.object(suite, name, **options))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            code = suite.main([*arguments, '--output-dir', str(self.root)])
        paths = set(self.root.glob('run-*')) - before
        # Locate this invocation's report without relying on random directory names or sort order.
        self.assertEqual(len(paths), 1)
        return code, json.loads((paths.pop() / 'summary.json').read_text()), mocks

    def test_linux_android_gate_never_probes_or_runs_macos(self):
        # An accidental Xcode probe raises an assertion immediately, even on a Mac running this test.
        with patch.object(suite.platform, 'system', return_value='Linux'), \
             patch.object(suite.subprocess, 'check_output', side_effect=AssertionError('Xcode probe')):
            code, report, mocks = self.invoke(['fast', '--android'])
        self.assertEqual(code, 0)
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['suites']['android']['passed'], 300)
        self.assertEqual(report['suites']['macos']['status'], 'not_selected')
        self.assertEqual(report['suites']['connected']['status'], 'not_selected')
        self.assertEqual(report['suites']['interchange']['status'], 'not_selected')
        self.assertEqual(report['requested_lanes'], ['contracts', 'rust', 'android'])
        mocks['run_macos_with_skips'].assert_not_called()
        mocks['run_connected_checks'].assert_not_called()
        mocks['run_interchange_checks'].assert_not_called()

    def test_linux_rejects_selected_macos_checks_with_a_saved_report(self):
        with patch.object(suite.platform, 'system', return_value='Linux'):
            code, report, mocks = self.invoke(['fast', '--macos'])
        self.assertEqual(code, 1)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('require macOS', report['errors'][0])
        mocks['run_macos_with_skips'].assert_not_called()

    def test_default_local_selection_and_explicit_omissions_are_preserved(self):
        with patch.object(suite.platform, 'system', return_value='Darwin'):
            code, report, mocks = self.invoke(['fast'])
            self.assertEqual(code, 0)
            mocks['run_android_jvm'].assert_called_once()
            mocks['run_macos_with_skips'].assert_called_once()
            self.assertEqual(report['suites']['macos']['documented_skips'], 3)
            self.assertEqual(report['requested_lanes'], ['contracts', 'rust', 'android', 'macos'])
            code, report, mocks = self.invoke(['fast', '--android', '--skip-rust'])
            self.assertEqual((code, report['status']), (0, 'passed_with_omissions'))
            mocks['run_rust'].assert_not_called()
            code, report, mocks = self.invoke(
                ['device', '--allow-no-device'],
                {'run_connected_checks': suite.NotExecuted('No authorized device'),
                 'run_interchange_checks': suite.NotExecuted('No authorized device')},
            )
            self.assertEqual((code, report['status']), (0, 'passed_with_omissions'))
            self.assertEqual(report['suites']['connected']['status'], 'not_executed')
            self.assertEqual(report['suites']['interchange']['status'], 'not_executed')

    def test_only_lane_selection_runs_exactly_that_lane(self):
        code, report, mocks = self.invoke(['--only', 'rust'])
        self.assertEqual(code, 0)
        self.assertEqual(report['requested_lanes'], ['rust'])
        self.assertEqual(report['suites']['rust']['passed'], 4)
        for name in ('ci-integrity', 'structure', 'vectors', 'python', 'android',
                     'macos', 'connected', 'interchange'):
            self.assertEqual(report['suites'][name]['status'], 'not_selected')
        mocks['run_rust'].assert_called_once()
        mocks['run_structure'].assert_not_called()
        mocks['run_android_jvm'].assert_not_called()

    def test_only_macos_lane_runs_only_macos(self):
        with patch.object(suite.platform, 'system', return_value='Darwin'):
            code, report, mocks = self.invoke(['--only', 'macos'])
        self.assertEqual(code, 0)
        self.assertEqual(report['requested_lanes'], ['macos'])
        self.assertEqual(report['suites']['macos']['passed'], 300)
        self.assertEqual(report['suites']['macos']['documented_skips'], 3)
        self.assertEqual(report['suites']['macos']['arch'], 'arm64')
        self.assertEqual(report['suites']['macos']['xcode'], 'Xcode 26.3')
        for name in ('ci-integrity', 'structure', 'vectors', 'python', 'rust',
                     'android', 'connected', 'interchange'):
            self.assertEqual(report['suites'][name]['status'], 'not_selected')
        mocks['run_macos_with_skips'].assert_called_once()
        mocks['run_android_jvm'].assert_not_called()

    def test_interchange_prepares_android_and_macos_toolchains_together(self):
        with patch.object(suite.platform, 'system', return_value='Darwin'):
            code, _, mocks = self.invoke(['--only', 'interchange'])
        self.assertEqual(code, 0)
        mocks['toolchain_env'].assert_called_once_with(android=True, macos=True, require_xcode=False)

    def test_macos_native_bridge_builds_before_the_xcode_test(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            macos = root / 'macos'
            library = macos / 'build' / 'native' / 'libanice_pairing.a'
            library.parent.mkdir(parents=True)
            # A previous archive must not survive to be linked by this run.
            library.write_bytes(b'stale')
            artifacts = root / 'artifacts'
            artifacts.mkdir()
            calls = []

            def fake_step(label, command, report_root, cwd=None, env=None, timeout=1800):
                calls.append((label, [str(part) for part in command]))
                log = report_root / (label.replace(' ', '_') + '.log')
                if label == 'macOS toolchain':
                    log.write_text('Xcode 26.3\nBuild version 17C529\n')
                elif label == 'macOS native pairing bridge':
                    library.write_bytes(b'fresh')
                elif label == 'macOS Release build':
                    bundle = root / 'derived/Build/Products/Release/aniCe.app'
                    for path in ('Contents/MacOS/aniCe', 'Contents/Helpers/aniCeUpdateHelper',
                                 'Contents/Resources/NowPlaying/libaniCeNowPlaying.dylib'):
                        binary = bundle / path
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(b'app-binary')
                    log.write_text('Release build completed\n')
                elif label in ('macOS architecture verification', 'macOS update helper architecture',
                               'macOS playback adapter architecture'):
                    self.assertEqual(str(command[1]), '-archs')
                    log.write_text('arm64\n')
                elif label == 'macOS codesign verification':
                    log.write_text('codesign valid\n')
                return log

            derived_dir = root / 'derived'
            derived_dir.mkdir(parents=True, exist_ok=True)
            with patch.object(suite, 'MACOS', macos), \
                 patch.object(suite.tempfile, 'mkdtemp', return_value=str(derived_dir)), \
                 patch.object(suite, 'run_step', side_effect=fake_step), \
                 patch.object(suite, 'parse_xcode_results', return_value=[]) as parse, \
                 patch.object(suite, 'validate_results', return_value=(1, 0)):
                result = suite.run_macos_with_skips({}, artifacts, (), ())

            self.assertEqual(result['passed'], 1)
            self.assertEqual(result['documented_skips'], 0)
            self.assertEqual(result['xcode'], 'Xcode 26.3')
            self.assertEqual(result['arch'], 'arm64')
            self.assertEqual(
                [label for label, _ in calls],
                [
                    'macOS toolchain',
                    'macOS native pairing bridge',
                    'macOS Release build',
                    'macOS architecture verification',
                    'macOS update helper architecture',
                    'macOS playback adapter architecture',
                    'macOS codesign verification',
                    'macOS hosted tests',
                ],
            )
            self.assertEqual(
                calls[1][1][1:],
                [str(suite.SCRIPTS / 'build-pairing-native.py'), 'macos'],
            )
            self.assertEqual(library.read_bytes(), b'fresh')
            self.assertEqual(parse.call_args.kwargs['env'], {})
            # Verify derived data was cleaned up on completion
            self.assertFalse(derived_dir.exists())

    def test_macos_lane_rejects_non_arm64_and_extra_architectures_in_every_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            macos = root / 'macos'
            library = macos / 'build' / 'native' / 'libanice_pairing.a'
            library.parent.mkdir(parents=True)
            artifacts = root / 'artifacts'
            artifacts.mkdir()

            def fake_step(label, command, report_root, cwd=None, env=None, timeout=1800):
                log = report_root / (label.replace(' ', '_') + '.log')
                if label == 'macOS toolchain':
                    log.write_text('Xcode 26.3\n')
                elif label == 'macOS native pairing bridge':
                    library.write_bytes(b'fresh')
                elif label == 'macOS Release build':
                    bundle = root / 'derived/Build/Products/Release/aniCe.app'
                    for path in ('Contents/MacOS/aniCe', 'Contents/Helpers/aniCeUpdateHelper',
                                 'Contents/Resources/NowPlaying/libaniCeNowPlaying.dylib'):
                        binary = bundle / path
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(b'app-binary')
                    log.write_text('Release build completed\n')
                elif 'architecture' in label:
                    log.write_text(architecture if label == failing_step else 'arm64\n')
                return log

            derived_dir = root / 'derived'
            for failing_step in ('macOS architecture verification', 'macOS update helper architecture',
                                 'macOS playback adapter architecture'):
                for architecture in ('x86_64\n', 'arm64 x86_64\n', 'arm64e\n', ''):
                    with self.subTest(step=failing_step, architecture=architecture):
                        derived_dir.mkdir(parents=True, exist_ok=True)
                        with patch.object(suite, 'MACOS', macos), \
                             patch.object(suite.tempfile, 'mkdtemp', return_value=str(derived_dir)), \
                             patch.object(suite, 'run_step', side_effect=fake_step):
                            with self.assertRaisesRegex(suite.GateError, 'must contain exactly arm64'):
                                suite.run_macos_with_skips({}, artifacts, (), ())
                        self.assertFalse(derived_dir.exists())

    def test_macos_lane_rejects_a_native_build_without_a_library(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            macos = root / 'macos'
            library = macos / 'build' / 'native' / 'libanice_pairing.a'
            library.parent.mkdir(parents=True)
            library.write_bytes(b'stale')
            artifacts = root / 'artifacts'
            artifacts.mkdir()
            with patch.object(suite, 'MACOS', macos), \
                 patch.object(suite, 'run_step') as command:
                with self.assertRaisesRegex(suite.GateError, 'no libanice_pairing.a'):
                    suite.run_macos_with_skips({}, artifacts, (), ())
            self.assertEqual([call.args[0] for call in command.call_args_list],
                             ['macOS toolchain', 'macOS native pairing bridge'])
            self.assertFalse(library.exists())

    def test_contracts_lane_runs_structure_vectors_and_python(self):
        code, report, mocks = self.invoke(['--only', 'contracts'])
        self.assertEqual(code, 0)
        self.assertEqual(report['requested_lanes'], ['contracts'])
        for name in ('structure', 'vectors', 'python'):
            self.assertEqual(report['suites'][name]['status'], 'passed')
        self.assertEqual(report['suites']['vectors']['checks'], len(suite.VECTOR_CHECKS))
        self.assertEqual(report['suites']['vectors']['oracle_tests'], 5)
        mocks['run_structure'].assert_called_once()
        mocks['run_vector_checks'].assert_called_once()
        mocks['run_python_meta_tests'].assert_called_once()
        mocks['run_rust'].assert_not_called()

    def test_ci_integrity_lane_reports_actionlint_and_policy_counts(self):
        code, report, mocks = self.invoke(['--only', 'ci-integrity'])
        self.assertEqual(code, 0)
        self.assertEqual(report['requested_lanes'], ['ci-integrity'])
        self.assertEqual(report['suites']['ci-integrity']['actionlint'], 'passed')
        self.assertEqual(report['suites']['ci-integrity']['policy_tests'], 12)
        mocks['run_ci_integrity'].assert_called_once()

    def test_device_lanes_can_be_selected_independently(self):
        with patch.object(suite.platform, 'system', return_value='Darwin'):
            code, report, mocks = self.invoke(['--only', 'connected'])
            self.assertEqual(code, 0)
            self.assertEqual(report['requested_lanes'], ['connected'])
            self.assertEqual(report['suites']['connected']['passed'], 10)
            self.assertEqual(report['suites']['interchange']['status'], 'not_selected')
            mocks['run_connected_checks'].assert_called_once()
            mocks['run_interchange_checks'].assert_not_called()
            code, report, mocks = self.invoke(['--only', 'interchange'])
            self.assertEqual(code, 0)
            self.assertEqual(report['requested_lanes'], ['interchange'])
            self.assertEqual(report['suites']['interchange']['harnesses'], 3)
            self.assertEqual(report['suites']['connected']['status'], 'not_selected')
            mocks['run_interchange_checks'].assert_called_once()
            mocks['run_connected_checks'].assert_not_called()

    def test_legacy_device_mode_runs_both_device_lanes(self):
        with patch.object(suite.platform, 'system', return_value='Darwin'):
            code, report, mocks = self.invoke(['device'])
        self.assertEqual(code, 0)
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['suites']['connected']['passed'], 10)
        self.assertEqual(report['suites']['interchange']['harnesses'], 3)
        mocks['run_interchange_checks'].assert_called_once()
        mocks['run_connected_checks'].assert_called_once()

    def test_only_and_mode_are_mutually_exclusive(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            suite.main(['fast', '--only', 'rust', '--output-dir', str(self.root)])
        self.assertEqual(raised.exception.code, 2)

    def test_allow_no_device_requires_a_device_lane(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            suite.main(['fast', '--allow-no-device', '--output-dir', str(self.root)])
        self.assertEqual(raised.exception.code, 2)

    def test_list_lanes_prints_the_workflow_interface(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = suite.main(['--list-lanes'])
        self.assertEqual(code, 0)
        self.assertIn('contracts: structure, vectors, python', output.getvalue())
        self.assertIn('macos: macos', output.getvalue())
        self.assertIn('interchange: interchange', output.getvalue())

    def test_markdown_summary_omits_unselected_suites_and_keeps_errors(self):
        summary = {
            'status': 'failed',
            'suites': {'rust': {'status': 'failed', 'passed': 3},
                       'macos': {'status': 'not_selected'}},
            'errors': ['fixture drift\nmore detail'],
        }
        text = suite.markdown_summary(summary)
        self.assertIn('| rust | failed | passed 3 |', text)
        self.assertNotIn('macos', text)
        self.assertIn('fixture drift more detail', text)

    def test_step_summary_is_written_when_github_provides_it(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'step-summary.md'
            with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(destination)}):
                code, report, _ = self.invoke(['--only', 'contracts'])
            self.assertEqual(code, 0)
            self.assertIn('Verification summary', destination.read_text())

    def test_connected_checks_fail_without_a_device_unless_omission_is_allowed(self):
        with patch.object(suite, 'find_adb', return_value='/adb'), \
             patch.object(suite, 'selected_device', return_value=None):
            with self.assertRaisesRegex(suite.GateError, 'require one authorized Android device'):
                suite.run_connected_checks(
                    SimpleNamespace(serial=None, allow_no_device=False), {}, self.root, ())
            with contextlib.redirect_stdout(io.StringIO()):
                result = suite.run_connected_checks(
                    SimpleNamespace(serial=None, allow_no_device=True), {}, self.root, ())
        self.assertEqual(result, suite.NotExecuted('No authorized device (--allow-no-device)'))

    def test_connected_checks_pass_the_selected_serial_to_gradle(self):
        with patch.object(suite, 'find_adb', return_value='/adb'), \
             patch.object(suite, 'selected_device', return_value='serial-1'), \
             patch.object(suite, 'run_connected_android', return_value=(10, 0)) as connected:
            env = {'PATH': '/bin'}
            result = suite.run_connected_checks(
                SimpleNamespace(serial='serial-1', allow_no_device=False), env, self.root, ())
        self.assertEqual(result, (10, 0))
        self.assertEqual(connected.call_args.args[0]['ANDROID_SERIAL'], 'serial-1')
        self.assertEqual(connected.call_args.kwargs, {})
        self.assertNotIn('ANDROID_SERIAL', env)

    def test_emulator_diagnostics_are_collected_before_return_and_preserve_test_failures(self):
        for test_failure, diagnostic_failure in (
            (None, None), (suite.GateError('original test failure'), None),
            (suite.GateError('original test failure'), suite.GateError('diagnostics unavailable')),
            (suite.GateError('original test failure'), PermissionError('diagnostics unwritable')),
            (None, suite.GateError('diagnostics unavailable')),
        ):
            with self.subTest(tests=test_failure, diagnostics=diagnostic_failure):
                calls = []
                def tests(*args, **kwargs):
                    calls.append('tests')
                    self.assertEqual(kwargs, {'preview': True})
                    if test_failure:
                        raise test_failure
                    return (10, 0)
                def diagnostics(label, command, artifacts, **kwargs):
                    calls.append('logcat')
                    self.assertEqual(command, ['/adb', '-s', 'emulator-5554', 'logcat', '-d'])
                    self.assertEqual(kwargs['env']['ANDROID_SERIAL'], 'emulator-5554')
                    if diagnostic_failure:
                        raise diagnostic_failure
                    return self.root / 'emulator-logcat.log'
                with patch.object(suite, 'find_adb', return_value='/adb'), \
                     patch.object(suite, 'selected_device', return_value='emulator-5554'), \
                     patch.object(suite, 'run_connected_android', side_effect=tests), \
                     patch.object(suite, 'run_step', side_effect=diagnostics), \
                     contextlib.redirect_stderr(io.StringIO()):
                    args = SimpleNamespace(serial='emulator-5554', allow_no_device=False)
                    expected = test_failure or diagnostic_failure
                    if expected:
                        with self.assertRaises(type(expected)) as raised:
                            suite.run_connected_checks(args, {}, self.root, ())
                        self.assertIs(raised.exception, expected)
                    else:
                        self.assertEqual(suite.run_connected_checks(args, {}, self.root, ()), (10, 0))
                self.assertEqual(calls, ['tests', 'logcat'])

    def test_toolchain_env_discovers_the_default_android_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            sdk = home / 'Library' / 'Android' / 'sdk'
            sdk.mkdir(parents=True)
            with patch.object(suite.Path, 'home', return_value=home), \
                 patch.dict(os.environ, {}, clear=True):
                env = suite.toolchain_env(android=True)
            self.assertEqual(env['ANDROID_HOME'], str(sdk))
            self.assertEqual(env['ANDROID_SDK_ROOT'], str(sdk))
            with patch.object(suite.Path, 'home', return_value=home), \
                 patch.dict(os.environ, {'ANDROID_SDK_ROOT': '/legacy/sdk'}, clear=True):
                env = suite.toolchain_env(android=True)
        self.assertEqual(env['ANDROID_HOME'], '/legacy/sdk')
        self.assertEqual(env['ANDROID_SDK_ROOT'], '/legacy/sdk')

    def test_toolchain_env_requires_a_complete_xcode_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            pin = Path(directory)
            with patch.dict(os.environ, {'DEVELOPER_DIR': str(pin)}, clear=True):
                with self.assertRaisesRegex(suite.GateError, 'not a full Xcode'):
                    suite.toolchain_env(macos=True, require_xcode=True)
            (pin / 'Platforms' / 'MacOSX.platform').mkdir(parents=True)
            with patch.dict(os.environ, {'DEVELOPER_DIR': str(pin)}, clear=True):
                env = suite.toolchain_env(macos=True, require_xcode=True)
        self.assertEqual(env['DEVELOPER_DIR'], str(pin))
        self.assertEqual(env['TEST_RUNNER_ANICE_RUN_KEYCHAIN_TESTS'], '1')

    def test_interchange_records_an_omission_without_a_device(self):
        with patch.object(suite, 'find_adb', return_value='/adb'), \
             patch.object(suite, 'selected_device', return_value=None), \
             contextlib.redirect_stdout(io.StringIO()):
            result = suite.run_interchange_checks(
                SimpleNamespace(serial=None, allow_no_device=True, session_mac_binary=None),
                {}, self.root)
        self.assertEqual(result, suite.NotExecuted('No authorized device (--allow-no-device)'))

    def test_interchange_execution_records_harnesses_and_manual_acceptance_metadata(self):
        with patch.object(suite, 'find_adb', return_value='/adb'), \
             patch.object(suite, 'selected_device', return_value='TEST_PHONE_SERIAL'), \
             patch.object(suite, 'run_step') as mock_step, \
             contextlib.redirect_stdout(io.StringIO()):
            result = suite.run_interchange_checks(
                SimpleNamespace(serial='TEST_PHONE_SERIAL', allow_no_device=False, session_mac_binary=Path('/mock/helper')),
                {}, self.root)
        self.assertEqual(result, {
            'harnesses': 3,
            'ble_verified': False,
            'manual_acceptance': 'pending',
        })
        self.assertEqual(mock_step.call_count, 3)

    def test_markdown_summary_formats_interchange_evidence(self):
        summary = {
            'status': 'passed',
            'suites': {
                'interchange': {
                    'status': 'passed',
                    'harnesses': 3,
                    'ble_verified': False,
                    'manual_acceptance': 'pending',
                }
            },
            'errors': [],
        }
        text = suite.markdown_summary(summary)
        self.assertIn('| interchange | passed | harnesses 3; ble verified False; manual acceptance pending |', text)

    def test_failure_marks_later_suites_unexecuted_and_returns_nonzero(self):
        code, report, mocks = self.invoke(['fast', '--android'],
                                        {'run_vector_checks': suite.GateError('fixture drift')})
        self.assertEqual((code, report['status']), (1, 'failed'))
        self.assertEqual(report['suites']['vectors']['status'], 'failed')
        self.assertEqual(report['suites']['android']['status'], 'not_executed')
        self.assertEqual(report['errors'], ['fixture drift'])
        mocks['run_android_jvm'].assert_not_called()

    def test_unwritable_report_root_cannot_pass(self):
        path = self.root / 'not-a-directory'
        path.write_text('occupied')
        output = io.StringIO()
        with contextlib.redirect_stderr(output), contextlib.redirect_stdout(io.StringIO()):
            code = suite.main(['fast', '--android', '--output-dir', str(path)])
        self.assertEqual(code, 1)
        self.assertIn('VERIFICATION FAILED', output.getvalue())
        self.assertEqual(path.read_text(), 'occupied')

    def test_summary_write_failure_does_not_hide_original_failure(self):
        original = suite.write_json
        # Revoke report writes only after the gate has already encountered its original failure.
        def fail_final_report(path, document):
            if document.get('status') == 'failed':
                raise PermissionError('reports revoked')
            return original(path, document)
        output = io.StringIO()
        with patch.object(suite, 'write_json', side_effect=fail_final_report), \
             patch.object(suite, 'run_structure', side_effect=suite.GateError('original gate failure')), \
             contextlib.redirect_stderr(output), contextlib.redirect_stdout(io.StringIO()):
            code = suite.main(['fast', '--android', '--output-dir', str(self.root)])
        self.assertEqual(code, 1)
        self.assertIn('original gate failure', output.getvalue())
        self.assertIn('reports revoked', output.getvalue())


class AndroidReportFreshnessTests(unittest.TestCase):
    # Seed or block old reports to prove a no-op runner cannot inherit a previous green result.
    def test_old_reports_are_removed_and_a_noop_runner_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = root / 'app/build/test-results/testDebugUnitTest'
            reports.mkdir(parents=True)
            (reports / 'old.xml').write_text('<testsuite tests="1"><testcase name="old"/></testsuite>')
            with patch.object(suite, 'ANDROID', root), patch.object(suite, 'run_step') as command:
                with self.assertRaisesRegex(suite.GateError, 'no JUnit reports'):
                    suite.run_android_jvm({}, root)
                self.assertIn('--no-build-cache', command.call_args.args[1])
                self.assertIn('assembleDebugAndroidTest', command.call_args.args[1])
            self.assertFalse(reports.exists())

    def test_emulator_lane_uses_preview_but_physical_lane_keeps_its_selected_package(self):
        for preview in (False, True):
            with self.subTest(preview=preview), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with patch.object(suite, 'ANDROID', root), patch.object(suite, 'run_step') as command:
                    with self.assertRaisesRegex(suite.GateError, 'no JUnit reports'):
                        suite.run_connected_android({}, root, (), preview=preview)
                self.assertEqual('-PanicePreview=true' in command.call_args.args[1], preview)

    def test_failed_report_cleanup_stops_before_running_gradle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'app/build/test-results/testDebugUnitTest').mkdir(parents=True)
            with patch.object(suite, 'ANDROID', root), \
                 patch.object(suite.shutil, 'rmtree', side_effect=PermissionError('cannot clear reports')), \
                 patch.object(suite, 'run_step') as command:
                with self.assertRaises(PermissionError):
                    suite.run_android_jvm({}, root)
                command.assert_not_called()

    def test_hosted_emulator_requires_the_synthetic_lan_regression_to_pass(self):
        identity = next(iter(suite.HOSTED_EMULATOR_REQUIRED_TESTS))
        test_class, test_name = identity.split("#")
        for outcome in ("passed", "skipped", "missing"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report = root / "app/build/outputs/androidTest-results/connected/TEST-LAN.xml"

                def gradle(*args, **kwargs):
                    report.parent.mkdir(parents=True)
                    result = '<testcase name="anotherTest"/>'
                    if outcome != "missing":
                        status = "<skipped/>" if outcome == "skipped" else ""
                        result = f'<testcase classname="pkg.{test_class}" name="{test_name}">{status}</testcase>'
                    report.write_text(f'<testsuite tests="1">{result}</testsuite>')

                with patch.object(suite, "ANDROID", root), \
                     patch.object(suite, "MINIMUM_CONNECTED", 1), \
                     patch.object(suite, "run_step", side_effect=gradle), \
                     patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), \
                     contextlib.redirect_stdout(io.StringIO()):
                    if outcome == "passed":
                        self.assertEqual(suite.run_connected_android({}, root, (identity,), preview=True), (1, 0))
                    else:
                        with self.assertRaisesRegex(suite.GateError, "Hosted emulator did not pass"):
                            suite.run_connected_android({}, root, (identity,), preview=True)
                    self.assertTrue((root / "android-connected-tests.json").is_file())

    def test_failed_gradle_run_surfaces_failing_junit_tests_and_persists_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / 'artifacts'
            artifacts.mkdir()
            reports = root / 'app/build/outputs/androidTest-results/connected'

            def failing_gradle(*args, **kwargs):
                reports.mkdir(parents=True, exist_ok=True)
                (reports / 'TEST-fail.xml').write_text(
                    '<testsuite name="pkg.Suite" tests="2" failures="1" errors="0" skipped="0">'
                    '<testcase classname="pkg.Suite" name="passes"/>'
                    '<testcase classname="pkg.Suite" name="crashes">'
                    '<failure message="\n  bad state\n::notice::injected">stack</failure></testcase>'
                    '</testsuite>'
                )
                raise suite.GateError('Android connected tests failed with exit 1; log: fake.log')

            stderr = io.StringIO()
            with patch.object(suite, 'ANDROID', root), \
                 patch.object(suite, 'run_step', side_effect=failing_gradle), \
                 patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                 contextlib.redirect_stderr(stderr):
                with self.assertRaises(suite.GateError) as raised:
                    suite.run_connected_android({}, artifacts, ())

            message = str(raised.exception)
            self.assertIn('1 failing test(s)', message)
            self.assertIn('pkg.Suite#crashes: bad state', message)
            self.assertIn('::error::Android connected: pkg.Suite#crashes', stderr.getvalue())
            self.assertNotIn('\n::notice::injected', stderr.getvalue())
            saved = json.loads((artifacts / 'android-connected-tests.json').read_text())
            self.assertEqual([row['name'] for row in saved], ['passes', 'crashes'])

    def test_find_adb_discovers_custom_env_and_linux_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'custom_sdk'
            adb = sdk / 'platform-tools/adb'
            adb.parent.mkdir(parents=True)
            adb.write_text('#!/bin/sh\nexit 0\n')
            adb.chmod(0o755)

            with patch.object(suite.shutil, 'which', return_value=None):
                # Custom env takes precedence over os.environ
                found = suite.find_adb(env={'ANDROID_HOME': str(sdk)})
                self.assertEqual(found, str(adb))

                # Discovery checks Linux home path
                linux_sdk = root / 'Android/Sdk'
                linux_adb = linux_sdk / 'platform-tools/adb'
                linux_adb.parent.mkdir(parents=True)
                linux_adb.write_text('#!/bin/sh\nexit 0\n')
                linux_adb.chmod(0o755)
                with patch.object(Path, 'home', return_value=root):
                    found_linux = suite.find_adb(env={})
                    self.assertEqual(found_linux, str(linux_adb))

    def test_connected_devices_passes_environment(self):
        test_env = {'ANDROID_SERIAL': 'emulator-5554'}
        with patch.object(suite.subprocess, 'run') as mock_run:
            mock_run.return_value = SimpleNamespace(
                returncode=0,
                stdout='List of devices attached\nemulator-5554\tdevice\n',
            )
            devices = suite.connected_devices('/mock/adb', env=test_env)
            self.assertEqual(devices, ['emulator-5554'])
            self.assertEqual(mock_run.call_args.kwargs['env'], test_env)


class VectorGateTests(unittest.TestCase):
    def test_every_fixture_generator_is_selected_without_rewriting_and_oracle_tests_are_counted(self):
        vectors = suite.ROOT / "protocol/test-vectors"
        generators = {path.resolve() for path in vectors.rglob("generate*.py")}
        selected = {vectors / path for _, path, _ in suite.VECTOR_CHECKS}
        self.assertEqual(generators, {path.resolve() for path in selected})
        self.assertEqual(len(suite.VECTOR_CHECKS), 19)
        self.assertIn(("SAS pairing vectors", "generate_sas_vectors.py", ()), suite.VECTOR_CHECKS)
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            with patch.object(suite, 'run_step', return_value=artifacts / 'oracle.log') as command, \
                 patch.object(suite, 'unittest_results', return_value=5) as parse, \
                 contextlib.redirect_stdout(io.StringIO()):
                result = suite.run_vector_checks('/oracle/python', artifacts)
        calls = command.call_args_list
        self.assertEqual(len(calls), len(suite.VECTOR_CHECKS) + 1)
        for call in calls[:-1]:
            self.assertEqual(call.args[1][0], '/oracle/python')
            self.assertIn('--check', call.args[1])
        self.assertIn('--lan-512', next(call.args[1] for call in calls if call.args[0] == 'LAN profile 4 vectors'))
        self.assertEqual(calls[-1].args[1][0], '/oracle/python')
        self.assertIn('test_*oracle.py', calls[-1].args[1])
        self.assertIn('-u', calls[-1].args[1])
        parse.assert_called_once_with(artifacts / 'oracle.log', minimum=5, label='Session crypto oracle')
        self.assertEqual(result, {'checks': 19, 'oracle_tests': 5})

    def test_fixture_checks_reject_drift_under_optimized_python_without_rewriting(self):
        root = suite.ROOT / "protocol/test-vectors"
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            for relative, fixture in (
                ("notifications/generate_notification_vectors.py", "notification-vectors.json"),
                ("phone-input/generate.py", "phone-input-vectors.json"),
                ("session/generate_control_vectors.py", "control-vectors.json"),
                ("lan/generate_bulk_probe_vectors.py", "bulk-probe-vectors.json"),
                ("lan/generate_lan_vectors.py", "lan-vectors.json"),
                ("lan/generate_lan_control_vectors.py", "automatic-vectors.json"),
                ("connection-pause/generate.py", "vectors.json"),
                ("generate_sas_vectors.py", "sas-vectors.json"),
            ):
                with self.subTest(generator=relative):
                    script = temporary / Path(relative).name
                    script.write_bytes((root / relative).read_bytes())
                    target = temporary / fixture
                    target.write_text("{}\n")
                    result = suite.subprocess.run(
                        [sys.executable, "-O", str(script), "--check"],
                        capture_output=True, text=True, timeout=15,
                    )
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(target.read_text(), "{}\n")

    def test_acceptance_scripts_do_not_use_optimization_removable_assertions(self):
        paths = list((suite.ROOT / "protocol/test-vectors").rglob("generate*.py"))
        paths.extend(suite.SCRIPTS / name for name in (
            "verify-suite.py", "ci_changes.py", "verify-identity-interchange.py", "verify-session-interchange.py",
            "verify-lan-interchange.py", "publish_release.py"))
        for path in paths:
            with self.subTest(path=path):
                tree = ast.parse(path.read_text())
                self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(tree)))


if __name__ == "__main__":
    unittest.main()
