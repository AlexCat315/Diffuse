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

```bash
cd guava-next
swift build
swift run EditorApp
```

## Next Steps

1. Replace CEngineBridge stubs with real C/C++ runtime hooks.
2. Add Metal-backed implementation in RenderBackend.
3. Implement window/input/menu adapters in PlatformShell.
4. Move existing editor panel models into EditorCore.
