# GuavaNext

A Swift-first refactor skeleton for engine + editor, with a C bridge reserved for performance-critical modules.

## Goals

- Keep editor and engine in one native process.
- Isolate platform integration in a thin shell layer.
- Keep performance hot paths behind a C ABI boundary.
- Make rendering backend pluggable (Metal now, wgpu later if needed).

## Module Layout

- Sources/EditorApp: executable entry.
- Sources/EditorCore: editor domain and orchestration.
- Sources/EngineCore: runtime and bridge adapters.
- Sources/RenderBackend: render backend abstraction.
- Sources/PlatformShell: platform shell abstraction.
- Sources/CEngineBridge: C ABI bridge stubs for future C/C++ modules.

## Build

Install the native dependencies once on macOS:

```bash
brew install sdl3 pkg-config
```

The wgpu-native dylib is not committed. Fetch it once before the first build:

```bash
cd packages/guava-next
./scripts/fetch-wgpu.sh   # downloads vendor/wgpu/ for current arch
swift build
swift run EditorApp
```

The pinned wgpu-native version lives in `scripts/fetch-wgpu.sh`. Update it
there and re-run the script to upgrade.

## Next Steps

1. Replace CEngineBridge stubs with real C/C++ runtime hooks.
2. Add Metal-backed implementation in RenderBackend.
3. Extend PlatformShell beyond the macOS Metal surface path.
4. Move existing editor panel models into EditorCore.
