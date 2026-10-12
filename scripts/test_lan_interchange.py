#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Rejects skipped, partial, misidentified and crashed native LAN instrumentation results.
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'lan_interchange', Path(__file__).with_name('verify-lan-interchange.py'))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


def event(code):
    return (f'INSTRUMENTATION_STATUS: class={harness.TEST}\n'
            'INSTRUMENTATION_STATUS: current=1\n'
            'INSTRUMENTATION_STATUS: numtests=1\n'
            'INSTRUMENTATION_STATUS: test=protectedTcpInterchange\n'
            f'INSTRUMENTATION_STATUS_CODE: {code}\n')


PASS = event(1) + event(0) + 'OK (1 test)\nINSTRUMENTATION_CODE: -1\n'


class LanInstrumentationGateTests(unittest.TestCase):
    def test_exact_completed_test_passes(self):
        harness.require_test(PASS)

    def test_false_success_is_rejected(self):
        cases = {
            'skip': PASS.replace('STATUS_CODE: 0', 'STATUS_CODE: -3'),
            'ignore': PASS.replace('STATUS_CODE: 0', 'STATUS_CODE: -4'),
            'assertion': PASS.replace('STATUS_CODE: 0', 'STATUS_CODE: -2'),
            'crash': PASS.replace('STATUS_CODE: 0', 'STATUS_CODE: -1'),
            'no_start': PASS.replace(event(1), ''),
            'no_finish': PASS.replace(event(0), ''),
            'no_tests': 'OK (1 test)\nINSTRUMENTATION_CODE: -1\n',
            'zero_tests': PASS.replace('OK (1 test)', 'OK (0 tests)'),
            'extra_test': PASS + event(0),
            'wrong_class': PASS.replace(harness.TEST, 'OtherTest'),
            'wrong_method': PASS.replace('protectedTcpInterchange', 'OtherMethod'),
            'wrong_inventory': PASS.replace('numtests=1', 'numtests=2'),
            'wrong_current': PASS.replace('current=1', 'current=2'),
            'no_result': PASS.replace('INSTRUMENTATION_CODE: -1\n', ''),
            'failed_result': PASS.replace('INSTRUMENTATION_CODE: -1', 'INSTRUMENTATION_CODE: 0'),
            'extra_result': PASS + 'INSTRUMENTATION_CODE: -1\n',
            'runner_failed': PASS + 'INSTRUMENTATION_FAILED\n',
            'runner_crashed': PASS + 'INSTRUMENTATION_RESULT: shortMsg=Process crashed\n',
            'failure_marker': PASS + 'FAILURES!!!\n',
        }
        self.assertGreaterEqual(len(cases), 19)
        for name, result in cases.items():
            with self.subTest(name=name), self.assertRaises(AssertionError):
                harness.require_test(result)


class LanDeadlineInventoryTests(unittest.TestCase):
    def test_expected_deadline_failure_is_not_a_pass_or_an_unrelated_failure(self):
        stack = ('INSTRUMENTATION_STATUS: stack=java.lang.AssertionError: Production DATA benchmark exceeded its completion budget\n'
                 'Caused by: kotlinx.coroutines.TimeoutCancellationException: Timed out\n')
        log = event(1) + stack + event(-2) + 'FAILURES!!!\nTests run: 1,  Failures: 1\nINSTRUMENTATION_CODE: -1\n'
        harness.require_deadline_failure(log)
        cases = [log.replace('STATUS_CODE: -2', 'STATUS_CODE: -3'),
                 log.replace('STATUS_CODE: -2', 'STATUS_CODE: 0'),
                 log.replace('exceeded its completion budget', 'Production journal changed'),
                 log.replace('numtests=1', 'numtests=2'),
                 log.replace('Caused by: kotlinx.coroutines.TimeoutCancellationException:', 'OtherFailure:')]
        self.assertGreaterEqual(len(cases), 5)
        for case in cases:
            with self.assertRaises(AssertionError):
                harness.require_deadline_failure(case)


class LanBenchmarkGateTests(unittest.TestCase):
    def metrics(self):
        common = dict(bytes=100 * 1048576, window=32)
        return (dict(common, androidSendMiBs=8.1, androidReceiveMiBs=8.2),
                dict(common, macSendMiBs=8.3, macReceiveMiBs=8.4))

    def test_throughput_does_not_claim_responsiveness(self):
        android, mac = self.metrics()
        result = harness.benchmark_result(android, mac, 100 * 1048576, 32)
        self.assertTrue(result['throughputPassed'])
        self.assertEqual(result['responsiveness'], 'pending')
        mac['macSendMiBs'] = 7.99
        self.assertFalse(harness.benchmark_result(android, mac, 100 * 1048576, 32)['throughputPassed'])

    def test_deadline_is_failure_and_cannot_fabricate_completed_traffic(self):
        progress = dict(bytes=100 * 1048576, window=32, completed=False,
                        throughputPassed=False, reason='completion-deadline',
                        androidReceivedBytes=0, androidAcknowledgedBytes=3072,
                        elapsedSeconds=60.01, androidCpuMs=20)
        self.assertFalse(harness.benchmark_deadline_result(progress, 100 * 1048576, 32)['throughputPassed'])
        invalid = [('completed', True), ('throughputPassed', True), ('elapsedSeconds', 1),
                   ('elapsedSeconds', float('nan')), ('androidReceivedBytes', -1),
                   ('androidAcknowledgedBytes', 101 * 1048576)]
        self.assertGreaterEqual(len(invalid), 6)
        for key, value in invalid:
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                harness.benchmark_deadline_result(dict(progress, **{key: value}), 100 * 1048576, 32)

    def test_missing_invalid_or_mismatched_measurements_are_rejected(self):
        cases = [float('nan'), float('inf'), -1, 0, True, '9']
        self.assertGreaterEqual(len(cases), 6)
        for value in cases:
            android, mac = self.metrics()
            mac['macSendMiBs'] = value
            with self.subTest(value=value), self.assertRaises(AssertionError):
                harness.benchmark_result(android, mac, 100 * 1048576, 32)
        for key in ('bytes', 'window'):
            android, mac = self.metrics()
            mac[key] += 1
            with self.subTest(key=key), self.assertRaises(AssertionError):
                harness.benchmark_result(android, mac, 100 * 1048576, 32)
        android, mac = self.metrics()
        del mac['macReceiveMiBs']
        with self.assertRaises(KeyError):
            harness.benchmark_result(android, mac, 100 * 1048576, 32)


if __name__ == '__main__':
    unittest.main()
