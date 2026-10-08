#!/usr/bin/env python3
"""Rebuild bundled NativeRHI renderer artifacts with the pinned offline Slang compiler."""
import argparse
import importlib.util
import json
import os
import tempfile
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
        ('shadow_mesh', 'shadow_mesh.slang', [('vertex', 'meshVertex'), ('fragment', 'shadowFragment')]),
        ('skybox', 'skybox.slang', [('vertex', 'skyVertex'), ('fragment', 'skyFragment')]),
        ('tonemap', 'tonemap.slang', [('vertex', 'toneVertex'), ('fragment', 'toneFragment')]),
        ('opaque_depth', 'opaque_mesh.slang', [('fragment', 'depthFragment')]),
        ('stylized_character', 'stylized_character.slang', [('vertex', 'meshVertex'), ('fragment', 'stylizedFragment')]),
        ('outline', 'outline.slang', [('vertex', 'outlineVertex'), ('fragment', 'outlineFragment')]),
        ('particles', 'particles.slang', [('vertex', 'particleVertex'), ('fragment', 'particleFragment')]),
        ('particle_cull_compact', 'particle_cull_compact.slang', [('compute', 'particleCull')]),
    ]
    programs.extend((name, f'{name}.slang', [('vertex', 'postVertex'), ('fragment', 'postFragment')])
                    for name in ['ssao','ssr','taa','bloom','fxaa','ink_paper_post'])
    particle_kernels = {
        'particle_simulate': 'particleSimulate', 'particle_spawn_append': 'particleSpawn',
        'particle_state_clear': 'particleClear', 'particle_state_compact': 'particleCompact',
        'particle_metadata_reset': 'particleMetadataReset', 'particle_state_finalize': 'particleFinalize',
    }
    specialized = set(particle_kernels) - {'particle_metadata_reset','particle_state_finalize'}
    programs.extend((name,f'{name}.slang',[('compute',entry)]) for name,entry in particle_kernels.items())
    for target in args.targets:
        for name, source, stages in programs:
            for stage, entry in stages:
                output = shaders / f'Native/{target}/{name}.{stage}.json'
                variable = name in specialized
                artifact = SHADER.compile_shader(shaders / 'Slang' / source, entry, stage, target, output, args.slangc,
                    threadgroup_size=[64,1,1] if variable else None, line_directives=False,
                    threadgroup_constants=[0,None,None] if variable and target != 'dxil' else None,
                    defines={'PARTICLE_WORKGROUP_SIZE': 64} if target == 'dxil' and name in particle_kernels else None)
                print(output.relative_to(ROOT))
                if variable and target == 'dxil':
                    # DXIL has fixed numthreads. Keep one reflected interface
                    # and a complete 1...256 code family, without 256 duplicate layouts.
                    codes = {'64': artifact['code']}
                    with tempfile.TemporaryDirectory(prefix='guava-dxil-workgroups-') as directory:
                        for size in range(1,257):
                            if size == 64: continue
                            variant = SHADER.compile_shader(shaders / 'Slang' / source,entry,stage,target,
                                Path(directory)/'shader.json',args.slangc,line_directives=False,defines={'PARTICLE_WORKGROUP_SIZE': size})
                            interface = dict(variant['interface']); interface['threadgroupSize'] = artifact['interface']['threadgroupSize']
                            if interface != artifact['interface']: raise ValueError('DXIL workgroup variant changes reflected ABI')
                            codes[str(size)] = variant['code']
                    output.with_name(f'{name}.compute.workgroups.json').write_text(json.dumps({'base': artifact,'variants': codes},indent=2)+'\n')


if __name__ == '__main__':
    main()
