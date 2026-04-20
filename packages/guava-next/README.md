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

## Backend Configuration

Choose backend order at startup:

```bash
swift run EditorApp --wgpu-backends metal,automatic
swift run EditorApp --wgpu-backends d3d12,vulkan,automatic
swift run EditorApp --wgpu-backends vulkan,automatic
```

You can also use a JSON file:

```json
{
	"wgpu": {
		"preferredBackends": ["vulkan", "automatic"],
		"validationEnabled": true,
		"framesInFlight": 2
	}
}
```

Run with:

```bash
swift run EditorApp --wgpu-config ./guava-next.json
```

Environment fallbacks are also supported:

```bash
export GUAVA_WGPU_BACKENDS="metal,automatic"
export GUAVA_WGPU_CONFIG="./guava-next.json"
```

## Next Steps

1. Replace CEngineBridge stubs with real C/C++ runtime hooks.
2. Validate the new Win32, Xlib, and Wayland surface paths on their target platforms.
3. Tune backend preference order per target deployment if the defaults are not suitable.
4. Move existing editor panel models into EditorCore.

## Backend Defaults

- macOS: Metal, then automatic fallback.
- Windows: D3D12, then Vulkan, then automatic fallback.
- Linux: Vulkan, then automatic fallback.
