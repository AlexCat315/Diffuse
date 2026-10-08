#!/usr/bin/env python3
"""Validate rejected shader interfaces and preservation of existing artifacts."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('rhi_shader', ROOT / 'scripts/compile-rhi-shader.py')
SHADER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHADER)


class ReflectionContractTests(unittest.TestCase):
    def test_specialization_constants_do_not_overlap_buffer_bindings(self):
        reflection = {'parameters': [
            {'name': 'size', 'binding': {'kind': 'specializationConstant', 'index': 0},
             'type': {'kind': 'scalar', 'scalarType': 'uint32'}},
            {'name': 'uniforms', 'binding': {'index': 0}, 'type': {'kind': 'constantBuffer'}},
        ]}
        self.assertEqual([item['name'] for item in SHADER.reflected_bindings(reflection)], ['uniforms'])
    def test_overlapping_target_namespaces_require_explicit_remapping(self):
        reflection = {'parameters': [
            {'name': 'constants', 'binding': {'index': 0}, 'type': {'kind': 'constantBuffer'}},
            {'name': 'image', 'binding': {'index': 0},
             'type': {'kind': 'resource', 'baseShape': 'texture2D'}},
        ]}
        with self.assertRaisesRegex(ValueError, 'overlap'):
            SHADER.reflected_bindings(reflection)

    def test_binding_arrays_are_rejected_instead_of_flattened(self):
        reflection = {'parameters': [
            {'name': 'images', 'binding': {'index': 0}, 'type': {'kind': 'array'}},
        ]}
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            SHADER.reflected_bindings(reflection)


@unittest.skipUnless(os.environ.get('SLANGC'), 'Set SLANGC to Slang 2026.19')
class CompilationFailureTests(unittest.TestCase):
    def assert_preserves_artifact(self, fixture, entry, stage, error_type, dimensions=None, constants=None):
        with tempfile.TemporaryDirectory(prefix='guava-rhi-negative-') as directory:
            output = Path(directory) / 'shader.json'
            reflection = output.with_suffix('.reflection.json')
            output.write_bytes(b'previous artifact')
            reflection.write_bytes(b'previous reflection')
            with self.assertRaises(error_type):
                SHADER.compile_shader(ROOT / f'Engine/Tests/NativeRHITests/Fixtures/{fixture}.slang',
                                      entry, stage, 'metal', output, os.environ['SLANGC'], dimensions,
                                      threadgroup_constants=constants)
            self.assertEqual(output.read_bytes(), b'previous artifact')
            self.assertEqual(reflection.read_bytes(), b'previous reflection')

    def test_compiler_failure_preserves_previous_output(self):
        self.assert_preserves_artifact('compute', 'absentEntry', 'compute', RuntimeError)

    def test_inconsistent_compute_local_size_preserves_previous_output(self):
        self.assert_preserves_artifact('compute', 'computeMain', 'compute', ValueError, [1, 1, 1])

    def test_missing_mesh_local_size_preserves_previous_output(self):
        self.assert_preserves_artifact('mesh', 'meshMain', 'mesh', ValueError)

    def test_specialized_local_size_requires_declared_default_and_integer_id(self):
        self.assert_preserves_artifact('specialization', 'specializedCompute', 'compute', ValueError)
        for constants in ([None,None,None], [3,None,None], [4,None,None], [0,1,None]):
            self.assert_preserves_artifact('specialization', 'specializedCompute', 'compute', ValueError,
                                          [64,1,1], constants)

    def test_specialized_defaults_and_typed_constants_survive_both_targets(self):
        with tempfile.TemporaryDirectory(prefix='guava-rhi-specialization-') as directory:
            for target in ('metal','spirv'):
                artifact = SHADER.compile_shader(ROOT / 'Engine/Tests/NativeRHITests/Fixtures/specialization.slang',
                    'specializedCompute', 'compute', target, Path(directory)/f'{target}.json',
                    os.environ['SLANGC'], [37,1,1], threadgroup_constants=[0,None,None])
                interface = artifact['interface']
                self.assertEqual(interface['threadgroupSize'], {'x': 37,'y': 1,'z': 1})
                self.assertEqual(interface['threadgroupSpecialization'], {'x': 0,'y': None,'z': None})
                self.assertEqual({item['id']: item['type'] for item in interface['specializationConstants']},
                                 {0:'uint32',1:'int32',2:'float32',3:'bool'})


if __name__ == '__main__':
    unittest.main()
