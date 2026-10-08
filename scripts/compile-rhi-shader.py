#!/usr/bin/env python3
"""Compile one entry point offline into NativeRHI's compiler-independent artifact.

The compiler is supplied explicitly, or through SLANGC. No downloads occur here.
Raw Slang reflection is saved beside the artifact for inspection. Reflection is retained in its target-specific form for binding-layout inspection.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile

SLANG_VERSION = '2026.19'


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip() or result.stderr.strip()


def parameter_bindings(parameter):
    return ([parameter['binding']] if 'binding' in parameter else []) + parameter.get('bindings', [])


def target_binding(parameter, target):
    bindings = parameter_bindings(parameter)
    priorities = ('constantBuffer', 'shaderResource', 'unorderedAccess', 'samplerState', 'descriptorTableSlot') if target == 'metal' else ('descriptorTableSlot', 'constantBuffer', 'shaderResource', 'unorderedAccess', 'samplerState')
    return next((binding for kind in priorities for binding in bindings if binding.get('kind') == kind), bindings[0] if bindings else {})


def reflected_constants(reflection, stage):
    result = []
    for parameter in reflection.get('parameters', []):
        bindings = parameter_bindings(parameter)
        if not any(binding.get('kind') == 'pushConstantBuffer' for binding in bindings):
            continue
        register = next((binding for binding in bindings if binding.get('kind') == 'descriptorTableSlot'), None)
        size = parameter['type']['elementVarLayout']['binding']['size']
        if register is None or register.get('space', 0) != 0 or size <= 0 or size % 4 or size > 128:
            raise ValueError('Push constants require a space0 register and at most 128 aligned bytes')
        result.append({'name': parameter['name'], 'slot': register['index'], 'byteCount': size, 'stage': stage})
    if len(result) > 1:
        raise ValueError('At most one push constant block per shader stage is supported')
    return result


def reflected_bindings(reflection, target='spirv', constants=()):
    result = []
    for parameter in reflection.get('parameters', []):
        if parameter['name'] in {item['name'] for item in constants}:
            continue
        binding = target_binding(parameter, target)
        type_info = parameter['type']
        kind = type_info.get('kind')
        shape = type_info.get('baseShape', '')
        if kind == 'samplerState':
            resource_type = 'sampler'
        elif kind == 'constantBuffer':
            resource_type = 'uniformBuffer'
        elif kind == 'resource' and shape in ('structuredBuffer', 'byteAddressBuffer'):
            resource_type = 'storageBuffer'
        elif kind == 'resource' and shape.startswith('texture'):
            resource_type = 'storageTexture' if type_info.get('access') == 'readWrite' else 'texture'
        elif kind == 'resource' and shape == 'accelerationStructure':
            resource_type = 'accelerationStructure'
        else:
            raise ValueError(f"Unsupported reflected binding {parameter['name']!r}: {kind}/{shape}")
        if 'index' not in binding:
            raise ValueError(f"Binding {parameter['name']!r} has no target resource index")
        buffer = {'readOnly': type_info.get('access') != 'readWrite', 'elementStride': 0}
        if shape == 'structuredBuffer':
            sizes = type_info.get('resultType', {}).get('sizes', [])
            size = next((item for item in sizes if item.get('kind') == 'uniform'), None)
            if size is None:
                raise ValueError(f"Missing structured element layout for {parameter['name']!r}")
            alignment = size.get('alignment', 1)
            buffer['elementStride'] = ((size['value'] + alignment - 1) // alignment) * alignment
        result.append({'name': parameter['name'], 'slot': binding['index'],
                       'space': binding.get('space', 0), 'type': resource_type, 'buffer': buffer})
    slots = [(item['space'], item['slot']) for item in result]
    if len(slots) != len(set(slots)):
        raise ValueError('Target bindings overlap; assign distinct slots before using the RHI direct-binding path')
    return result


def compile_shader(source, entry, stage, target, output, compiler, threadgroup_size=None, line_directives=True):
    version = run([compiler, '-version'])
    if version != SLANG_VERSION:
        raise ValueError(f'Expected Slang {SLANG_VERSION}, got {version!r}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='guava-rhi-shader-') as directory:
        temp = Path(directory)
        code = temp / {'metal': 'shader.metal', 'spirv': 'shader.spv', 'dxil': 'shader.dxil'}[target]
        reflection_file = temp / 'reflection.json'
        arguments = [compiler, str(source.resolve()), '-entry', entry, '-stage', stage,
                     '-target', target, '-o', str(code), '-reflection-json', str(reflection_file)]
        if target == 'spirv': arguments += ['-fvk-use-entrypoint-name']
        if target == 'dxil': arguments += ['-profile', 'sm_6_6']
        if not line_directives: arguments += ['-line-directive-mode', 'none']
        run(arguments)
        reflection = json.loads(reflection_file.read_text())
        logical_reflection = reflection
        if target != 'spirv':
            logical_file = temp / 'logical.json'
            run([compiler, str(source.resolve()), '-entry', entry, '-stage', stage, '-target', 'spirv',
                 '-o', str(temp / 'logical.spv'), '-reflection-json', str(logical_file), '-fvk-use-entrypoint-name'])
            logical_reflection = json.loads(logical_file.read_text())
        constants = reflected_constants(logical_reflection, stage)
        for constant in constants:
            parameter = next(p for p in reflection['parameters'] if p['name'] == constant['name'])
            if target != 'spirv': constant['slot'] = target_binding(parameter, target)['index']
        entry_reflection = next(item for item in reflection['entryPoints'] if item['name'] == entry)
        dimensions = entry_reflection.get('threadGroupSize')
        if stage in ('mesh', 'task') and dimensions is None and threadgroup_size is None:
            raise ValueError('Slang JSON does not expose mesh/task local size; supply --threadgroup-size X Y Z matching numthreads')
        if dimensions is not None and threadgroup_size is not None and dimensions != threadgroup_size:
            raise ValueError('Explicit local size disagrees with compiler reflection')
        dimensions = dimensions or threadgroup_size or [1, 1, 1]
        if len(dimensions) != 3 or any(value <= 0 for value in dimensions):
            raise ValueError('Invalid reflected workgroup size')
        format_name = {'metal': 'mslSource', 'spirv': 'spirv', 'dxil': 'dxil'}[target]
        artifact = {
            'stage': stage, 'format': format_name, 'entryPoint': entry,
            'code': base64.b64encode(code.read_bytes()).decode('ascii'),
            'interface': {'threadgroupSize': dict(zip(('x', 'y', 'z'), dimensions)),
                          'bindings': reflected_bindings(reflection, target, constants),
                          'pushConstants': [{k: v for k, v in c.items() if k != 'name'} for c in constants]},
            'compiler': f'Slang {version}',
        }
        # Compilation must finish before an artifact is published.
        output.with_suffix('.reflection.json').write_text(json.dumps(reflection, indent=2) + '\n')
        output.write_text(json.dumps(artifact, indent=2) + '\n')
    return artifact


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--entry', required=True)
    parser.add_argument('--stage', choices=['vertex', 'fragment', 'compute', 'task', 'mesh'], required=True)
    parser.add_argument('--target', choices=['metal', 'spirv', 'dxil'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--threadgroup-size', nargs=3, type=int)
    parser.add_argument('--no-line-directives', action='store_true', help='Omit absolute source paths from bundled shader code')
    parser.add_argument('--slangc', default=os.environ.get('SLANGC'))
    args = parser.parse_args()
    if not args.slangc:
        parser.error('Supply --slangc or SLANGC (Slang 2026.19)')
    try:
        compile_shader(args.source, args.entry, args.stage, args.target, args.output, args.slangc, args.threadgroup_size, not args.no_line_directives)
    except (RuntimeError, ValueError, OSError, KeyError, StopIteration) as error:
        parser.exit(1, f'Shader compilation failed: {error}\n')
    print(args.output)


if __name__ == '__main__':
    main()
