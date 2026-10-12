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
    parser.add_argument('--check', action='store_true', help='Compile into temporary storage and reject stale bundled artifacts')
    parser.add_argument('--ui-only', action='store_true', help='Rebuild only the GuavaUI artifacts')
    args = parser.parse_args()
    if not args.slangc:
        bundled = ROOT / 'Engine/vendor/slang/bin/slangc'
        if bundled.is_file(): args.slangc = str(bundled)
        else: parser.error('Supply --slangc or SLANGC (Slang 2026.19)')
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
        'particle_sort_prepare': 'particleSortPrepare', 'particle_sort_bitonic': 'particleSortBitonic',
        'particle_sim_to_instance': 'particleSimToInstance',
    }
    specialized = set(particle_kernels) - {'particle_metadata_reset','particle_state_finalize'}
    programs.extend((name,f'{name}.slang',[('compute',entry)]) for name,entry in particle_kernels.items())
    programs = [(shaders, *program) for program in programs] if not args.ui_only else []
    ui_shaders = ROOT / 'GuavaUI/Sources/GuavaUIRuntime/Resources/Shaders'
    programs.append((ui_shaders, 'ui', 'ui.slang', [('vertex', 'uiVertex'), ('fragment', 'uiFragment')]))
    programs.append((ui_shaders, 'ui_backdrop', 'ui_backdrop.slang',
                     [('vertex', 'backdropVertex'), ('fragment', 'backdropFragment')]))
    with tempfile.TemporaryDirectory(prefix='guava-native-shaders-') as staging:
        destinations = []
        for target in args.targets:
            for shaders, name, source, stages in programs:
                for stage, entry in stages:
                    destination = shaders / f'Native/{target}/{name}.{stage}.json'
                    output = Path(staging) / destination.relative_to(ROOT)
                    destinations.append((output, destination))
                    variable = name in specialized
                    defines = {'PARTICLE_WORKGROUP_SIZE': 64} if target == 'dxil' and name in particle_kernels else None
                    if name == 'ui': defines = {'UI_VERTEX_SHADER': int(stage == 'vertex')}
                    if name == 'ui_backdrop': defines = {'BACKDROP_VERTEX_SHADER': int(stage == 'vertex')}
                    artifact = SHADER.compile_shader(shaders / 'Slang' / source, entry, stage, target, output, args.slangc,
                        threadgroup_size=[64,1,1] if variable else None, line_directives=False,
                        threadgroup_constants=[0,None,None] if variable and target != 'dxil' else None,
                        defines=defines, spirv_profile="spirv_1_3" if name in ("ui", "ui_backdrop") else "spirv_1_5")
                    print(destination.relative_to(ROOT))
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
                        family = output.with_name(f'{name}.compute.workgroups.json')
                        destinations.append((family, destination.with_name(f'{name}.compute.workgroups.json')))
                        family.write_text(json.dumps({'base': artifact,'variants': codes},indent=2)+'\n')

        pairs = []
        for output, destination in destinations:
            if output.with_suffix('.reflection.json').exists():
                pairs.append((output.with_suffix('.reflection.json'), destination.with_suffix('.reflection.json')))
            pairs.append((output, destination))
        if args.check:
            stale = [str(destination.relative_to(ROOT)) for output, destination in pairs
                     if not destination.is_file() or json.loads(output.read_text()) != json.loads(destination.read_text())]
            if stale: raise SystemExit('Stale native shader artifacts:\n' + '\n'.join(stale))
            print(f'Verified {len(destinations)} bundled shader artifacts')
        else:
            for output, destination in pairs:
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Compile failures preserve the full previous batch. Publication
                # stages each file on its destination filesystem for atomic replace.
                with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as pending:
                    pending.write(output.read_bytes())
                    pending_path = Path(pending.name)
                try: os.replace(pending_path, destination)
                finally: pending_path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
