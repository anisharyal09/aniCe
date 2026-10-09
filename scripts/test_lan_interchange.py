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


if __name__ == '__main__':
    unittest.main()
