#!/usr/bin/env python3
"""Rebuild bundled NativeRHI renderer artifacts with the pinned offline Slang compiler."""
import argparse
import importlib.util
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('rhi_shader', ROOT / 'scripts/compile-rhi-shader.py')
SHADER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHADER)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--slangc', default=os.environ.get('SLANGC'))
    parser.add_argument('--targets', nargs='+', choices=['metal', 'spirv', 'dxil'], default=['metal', 'spirv'])
    args = parser.parse_args()
    if not args.slangc:
        parser.error('Supply --slangc or SLANGC (Slang 2026.19)')
    shaders = ROOT / 'Engine/Sources/RenderBackend/Resources/Shaders'
    programs = [
        ('editor_grid', 'editor_grid.slang', [('vertex', 'gridVertex'), ('fragment', 'gridFragment')]),
        ('opaque_mesh', 'opaque_mesh.slang', [('vertex', 'meshVertex'), ('fragment', 'meshFragment')]),
        ('opaque_depth', 'opaque_mesh.slang', [('fragment', 'depthFragment')]),
    ]
    for target in args.targets:
        for name, source, stages in programs:
            for stage, entry in stages:
                output = shaders / f'Native/{target}/{name}.{stage}.json'
                SHADER.compile_shader(shaders / 'Slang' / source, entry, stage, target, output, args.slangc,
                                      line_directives=False)
                print(output.relative_to(ROOT))


if __name__ == '__main__':
    main()
