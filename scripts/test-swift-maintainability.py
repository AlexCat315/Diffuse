#!/usr/bin/env python3
"""Regression examples for the structural Swift guard."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("guard", Path(__file__).with_name("check-swift-maintainability.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class StructuralGuardTests(unittest.TestCase):
    def test_stored_properties_exclude_static_computed_and_string_contents(self):
        source = '''
        struct Configuration {
            static let global = 0
            var count: Int = 0
            let text = "struct Fake { var fake: Int }"
            var computed: Int { count * 2 }
            var observed: Int { didSet { print(observed) } }
            // var commented: Int
        }
        '''
        self.assertEqual(guard.measure(source)["Configuration"]["stored_properties"], 3)

    def test_generics_and_closures_do_not_inflate_parameter_counts(self):
        source = '''
        struct Configuration {
            var value = 0
            init(values: Dictionary<String, Int>, apply: (Int, Int) -> Int = { a, b in a + b }) {
                self.value = apply(1, 2)
            }
        }
        '''
        metrics = guard.measure(source)["Configuration"]
        self.assertEqual(metrics["initializer_parameters"], 2)
        self.assertEqual(metrics["initializer_assignments"], 1)

    def test_nested_types_are_counted_independently(self):
        source = "struct Outer { var x = 0; struct Inner { var a = 0; var b = 1 } }"
        metrics = guard.measure(source)
        self.assertEqual(metrics["Outer"]["stored_properties"], 1)
        self.assertEqual(metrics["Outer.Inner"]["stored_properties"], 2)

    def test_class_methods_do_not_create_fake_types(self):
        self.assertEqual(set(guard.measure("class Factory { class func make() -> Int { 1 } }")), {"Factory"})

    def test_large_property_list_is_detected(self):
        source = "struct Oversized {\n" + "\n".join(f"var field{i} = 0" for i in range(21)) + "\n}"
        self.assertGreater(guard.measure(source)["Oversized"]["stored_properties"], guard.LIMITS["stored_properties"])


if __name__ == "__main__":
    unittest.main()
