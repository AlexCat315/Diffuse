#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${GUAVA_GPU_TEST_OUTPUT_DIR:-$repo_root/Engine/build/gpu-regression}"
mkdir -p "$output_dir"
report_dir="$(mktemp -d "$output_dir/run-XXXXXX")"
export GUAVA_RUN_GPU_SMOKE_TESTS=1
export GUAVA_GPU_SMOKE_OUTPUT="$output_dir/render.ppm"
export GUAVA_GRID_SMOKE_OUTPUT="$output_dir/grid.ppm"
export GUAVA_SHADOW_SMOKE_OUTPUT="$output_dir/shadow.ppm"

# Run a fixed regression inventory, so newly introduced hardware/performance
# experiments do not silently make this rendering job unbounded.
filter='RenderBackendGPUSmokeTests/(material|largeSceneMesh|directionalShadow|multiDirectionalShadow|directionalCascades|editorGrid|skinned|opaqueCache)|ShaderCatalogTests'
"${GUAVA_SWIFT_EXECUTABLE:-swift}" test --package-path "$repo_root/Engine" \
  --filter "$filter" --xunit-output "$report_dir/gpu-results.xml" 2>&1 | tee "$output_dir/gpu.log"

# A successful command that selected no tests, or skipped all GPU tests, must
# fail this job. Real adapter/pipeline/readback failures also fail Swift tests.
python3 - "$report_dir" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET
# SwiftPM appends -swift-testing to Swift Testing reports. A fresh directory
# prevents reports from an earlier run from satisfying the inventory check.
reports = list(Path(sys.argv[1]).glob('gpu-results*.xml'))
if not reports:
    raise SystemExit('GPU regression did not produce an xUnit report')
cases = [case for path in reports for case in ET.parse(path).getroot().iter('testcase')]
gpu = [case for case in cases if 'RenderBackendGPUSmoke' in (case.get('classname', '') + case.get('name', ''))]
required = {
    'materialTransparency', 'materialDoubleSided', 'materialPrimitiveCoverage',
    'materialMaskDepthAndShadow', 'largeSceneMeshBatches',
    'directionalShadowPassDarkensOccludedPixels', 'multiDirectionalShadowAtlasEncodesOneTilePerLight',
    'directionalCascadesEncodeOneAtlasTilePerCascade', 'skinnedMeshPaletteDoesNotCrashGPUPipeline',
    'editorGridPaintsEmptyViewport', 'editorGridOrthographicPlanes', 'editorGridDepthAndHorizon',
    'opaqueCacheOverlayMatchesFullRender', 'opaqueCacheConvergesUnderTAA',
}
executed = {case.get('name', '').split('(')[0] for case in gpu}
if required - executed:
    raise SystemExit(f'GPU regression inventory is incomplete: {sorted(required - executed)}')
if any(case.find('skipped') is not None or case.find('failure') is not None or case.find('error') is not None for case in gpu):
    raise SystemExit('GPU regression report contains skipped or failed GPU tests')
print(f'GPU regression verified: {len(gpu)} hardware test functions executed')
PY
