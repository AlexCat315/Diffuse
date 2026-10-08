This directory contains offline shader assets for the Swift Engine renderer.

- `manifest.json` and `WGSL/` serve the production WGPU reference renderer.
- `Slang/` contains NativeRHI grid, indexed mesh/depth, shadow, sky and tonemap sources.
- `Native/metal/` and `Native/spirv/` contain compiled `ShaderArtifact` JSON and target reflection. Runtime execution does not load Slang.

Rebuild with Slang 2026.19 using `scripts/compile-native-renderer-shaders.py`.
For Windows, generate `Native/dxil/` with `--targets dxil` and an installed DXC library. DX12 renderer artifacts are still pending; missing artifacts throw explicitly.

macOS uses Metal. SPIR-V is for native Windows/Linux Vulkan and is not validated through a macOS portability driver.
