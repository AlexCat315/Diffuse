#!/usr/bin/env python3
"""Guard CI against unrun, skipped, failed, or partially reported GPU tests."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location('gpu_verifier', Path(__file__).with_name('verify-gpu-regression.py'))
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class RegressionInventoryTests(unittest.TestCase):
    def test_started_tests_and_suite_summaries_cannot_satisfy_inventory(self):
        cases = VERIFIER.xctest_cases("Test Case '-[Module.SceneTests draw]' started.\n"
                                     "Test Suite 'SceneTests' passed at 2026-10-11.\n")
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            VERIFIER.verify_cases(cases, {'SceneTests'}, {'draw'})

    def test_completed_apple_and_portable_xctest_records_satisfy_inventory(self):
        cases = VERIFIER.xctest_cases("Test Case '-[Module.SceneTests draw]' passed (0.012 seconds).\n"
                                     "Test Case 'SurfaceTests.resize' passed (0.023 seconds).\n")
        VERIFIER.verify_cases(cases, {'SceneTests', 'SurfaceTests'}, {'draw', 'resize'})

    def test_skipped_or_failed_test_fails_even_when_required_tests_pass(self):
        for status in ('skipped', 'failed'):
            cases = VERIFIER.xctest_cases("Test Case 'SceneTests.draw' passed (0.012 seconds).\n"
                                         f"Test Case 'SceneTests.resize' {status} (0.023 seconds).\n")
            with self.assertRaisesRegex(ValueError, 'skipped or failed'):
                VERIFIER.verify_cases(cases, {'SceneTests'}, {'draw'})

    def test_missing_suite_or_method_fails(self):
        cases = VERIFIER.xctest_cases("Test Case 'SceneTests.draw' passed (0.012 seconds).\n")
        for suites, methods in [({'SurfaceTests'}, {'draw'}), ({'SceneTests'}, {'resize'})]:
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                VERIFIER.verify_cases(cases, suites, methods)

    def test_swift_testing_xml_and_xctest_log_are_both_required_and_merged(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'gpu-results-swift-testing.xml').write_text(
                '<testsuite><testcase classname="Module.SmokeTests" name="render()"/></testsuite>')
            (directory / 'gpu.log').write_text("Test Case '-[Module.SurfaceTests resize]' passed (0.023 seconds).\n")
            cases = VERIFIER.load_cases(directory, 'gpu')
            VERIFIER.verify_cases(cases, {'SmokeTests', 'SurfaceTests'}, {'render', 'resize'})
            self.assertEqual(len(list(ET.parse(directory / 'gpu-xctest.xml').getroot())), 1)

    def test_native_xml_is_not_counted_twice_and_cannot_hide_a_logged_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'ui-results.xml').write_text(
                '<testsuite><testcase classname="Module.SurfaceTests" name="resize"/></testsuite>')
            log = directory / 'ui.log'
            log.write_text("Test Case '-[Module.SurfaceTests resize]' passed (0.023 seconds).\n")
            self.assertEqual(len(VERIFIER.load_cases(directory, 'ui')), 1)
            log.write_text("Test Case '-[Module.SurfaceTests resize]' failed (0.023 seconds).\n")
            with self.assertRaisesRegex(ValueError, 'skipped or failed'):
                VERIFIER.verify_cases(VERIFIER.load_cases(directory, 'ui'), {'SurfaceTests'}, {'resize'})

    def test_missing_xml_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'did not produce'):
                VERIFIER.load_cases(Path(temporary), 'gpu')


if __name__ == '__main__':
    unittest.main()
