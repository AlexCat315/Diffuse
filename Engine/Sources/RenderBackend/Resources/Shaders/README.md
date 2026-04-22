This directory contains shader source assets for the Swift Engine renderer.

- `manifest.json` is the shader catalog consumed by `RenderBackend`.
- `WGSL/` contains the catalog-wide shader sources.

The catalog is now WGSL-only. Some entries are already runtime-wired in `WGPURenderer`; the rest are source-level WGSL ports kept ready for later feature wiring.