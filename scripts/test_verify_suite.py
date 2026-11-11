#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial checks for the aggregate verification gate (no device required)."""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
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
            "truncated": "Ran 18 tests in 0.120s\n",
            "expected_failures": "Ran 18 tests in 0.120s\n\nOK (expected failures=1)\n",
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
            'run_ci_integrity': {'actionlint': 'passed', 'policy_tests': 12},
            'run_structure': None, 'vector_interpreter': sys.executable,
            'run_vector_checks': 13, 'run_python_meta_tests': 30, 'run_rust': 4,
            'run_android_jvm': (300, 0), 'run_macos_with_skips': (300, 3),
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
        for name in ('ci-integrity', 'structure', 'vectors', 'python', 'rust',
                     'android', 'connected', 'interchange'):
            self.assertEqual(report['suites'][name]['status'], 'not_selected')
        mocks['run_macos_with_skips'].assert_called_once()
        mocks['run_android_jvm'].assert_not_called()

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
                    binary = root / 'derived' / 'Build' / 'Products' / 'Release' / 'aniCe.app' / 'Contents' / 'MacOS' / 'aniCe'
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    binary.write_bytes(b'app-binary')
                    log.write_text('Release build completed\n')
                elif label == 'macOS architecture verification':
                    log.write_text('Non-fat file (architecture arm64)\n')
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

    def test_macos_lane_rejects_app_binary_missing_arm64(self):
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
                    binary = root / 'derived' / 'Build' / 'Products' / 'Release' / 'aniCe.app' / 'Contents' / 'MacOS' / 'aniCe'
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    binary.write_bytes(b'app-binary')
                    log.write_text('Release build completed\n')
                elif label == 'macOS architecture verification':
                    # Missing arm64
                    log.write_text('Non-fat file (architecture x86_64)\n')
                return log

            derived_dir = root / 'derived'
            derived_dir.mkdir(parents=True, exist_ok=True)
            with patch.object(suite, 'MACOS', macos), \
                 patch.object(suite.tempfile, 'mkdtemp', return_value=str(derived_dir)), \
                 patch.object(suite, 'run_step', side_effect=fake_step):
                with self.assertRaisesRegex(suite.GateError, 'does not contain arm64'):
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
        self.assertEqual(report['suites']['vectors']['checks'], 13)
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
        self.assertNotIn('ANDROID_SERIAL', env)

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
             patch.object(suite, 'selected_device', return_value='RZCW916NELW'), \
             patch.object(suite, 'run_step') as mock_step, \
             contextlib.redirect_stdout(io.StringIO()):
            result = suite.run_interchange_checks(
                SimpleNamespace(serial='RZCW916NELW', allow_no_device=False, session_mac_binary=Path('/mock/helper')),
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


if __name__ == "__main__":
    unittest.main()
