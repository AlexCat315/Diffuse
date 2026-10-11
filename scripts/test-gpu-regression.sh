#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${GUAVA_GPU_TEST_OUTPUT_DIR:-$repo_root/Engine/build/gpu-regression}"
mkdir -p "$output_dir"
report_dir="$(mktemp -d "$output_dir/run-XXXXXX")"
export GUAVA_RUN_GPU_SMOKE_TESTS=1
export GUAVA_GPU_TEST_OUTPUT_DIR="$output_dir"

# Run a fixed regression inventory, so newly introduced hardware/performance
# experiments do not silently make this rendering job unbounded.
filter='RenderBackendGPUSmokeTests|ShaderCatalogTests|NativeOpaqueTests|NativePBRTests|NativePostTests|NativeAnimatedMeshTests|NativeStylizedTests|NativeParticleTests|NativeParticleSimulationTests|NativeParticleInstanceTests|NativeViewportSurfaceTests|NativeEditorGridTests|RenderThreadTests'
"${GUAVA_SWIFT_EXECUTABLE:-swift}" test --package-path "$repo_root/Engine" \
  --filter "$filter" --xunit-output "$report_dir/gpu-results.xml" 2>&1 | tee "$report_dir/gpu.log"

ui_filter='NativeAppWindowTests|NativeInGameUIIntegrationTests|NativeInGameUILifecycleTests|NativeViewportIntegrationTests|NativeDrawListParityTests|NativeImageAssetTests|NativeUIBindingReuseTests'
"${GUAVA_SWIFT_EXECUTABLE:-swift}" test --package-path "$repo_root/GuavaUI" \
  --filter "$ui_filter" --xunit-output "$report_dir/ui-results.xml" 2>&1 | tee "$report_dir/ui.log"

# A successful command that selected no tests, or skipped all GPU tests, must
# fail this job. Real adapter/pipeline/readback failures also fail Swift tests.
python3 "$repo_root/scripts/verify-gpu-regression.py" "$report_dir"
