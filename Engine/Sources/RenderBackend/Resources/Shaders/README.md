This directory contains offline NativeRHI shader assets.

- `Slang/` is the authored source for scene, lighting, post, grid and particle passes.
- `Native/metal/` and `Native/spirv/` contain ShaderArtifact JSON and target reflection. Runtime execution does not load Slang.
- `Native/spirv-mobile/` contains Android Vulkan 1.1 / SPIR-V 1.3 artifacts. Particle compute shaders use offline fixed workgroup variants from 1 through 256, sharing the base reflection ABI, so mobile drivers do not need maintenance4 / LocalSizeId. Rebuild with `--targets spirv-mobile`; see [Android validation and export](../../../../../Platforms/Android/README.md).

Install the pinned Slang 2026.19 compiler with `swift run --package-path Tools/Developer cove-dev shader bootstrap-slang` on macOS arm64, or set `SLANGC` on other hosts. Rebuild all scene and CoveUI artifacts with `swift run --package-path Tools/Developer cove-dev shader rebuild`. Use `--check` to compile and verify checked-in artifacts without changing them. A failed batch preserves existing artifacts.

macOS defaults to Metal, Windows to DX12, and Linux to native Vulkan. Windows tries Vulkan if DX12 device creation fails. Generate `Native/dxil/` with `--targets dxil` and an installed DXC library before running the DX12 renderer. DXIL renderer artifacts are not bundled yet; missing artifacts fail explicitly.

Current GPU regression: `swift run --package-path Tools/Developer cove-dev gpu-regression run`. `swift run --package-path Engine NativeRHIPassProbe --scene post --backends metal --frames 6 --warmup 3 --repeats 1 --output /tmp/cove-native-post` measures selected native backends and exports pixels. Multiple `--backends` values compare native workloads and images against the first backend.
