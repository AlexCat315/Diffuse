# Renderer API

> Source: [`src/engine/render/renderer.zig`](../../src/engine/render/renderer.zig)

## Overview

The Renderer manages the full rendering pipeline:

1. **Depth Prepass** — depth buffer pre-fill for optimization
2. **Shadow Pass** — shadow map generation
3. **Base Pass** — PBR scene geometry
4. **Skybox Pass** — environment / sky
5. **SSAO** — screen-space ambient occlusion
6. **SSGI** — screen-space global illumination
7. **Contact Shadows** — per-pixel shadow detail
8. **SSR** — screen-space reflections
9. **Volumetric Fog** — atmospheric scattering
10. **Bloom** — bright-area glow
11. **DoF** — depth of field (CoC → Blur → Composite)
12. **TAA** — temporal anti-aliasing
13. **FXAA** — fast approximate anti-aliasing
14. **Tonemap** — HDR → LDR tone mapping
15. **Gizmo Pass** — editor manipulators
16. **Outline Pass** — selection highlight
17. **ID Pass** — entity picking

---

## Lifecycle

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `(allocator, RendererConfig) !Renderer` | Create renderer with GPU device |
| `deinit` | `(*Renderer) void` | Release all GPU resources |
| `drawFrame` | `(*Renderer, *Scene, ?*PhysicsState) !FrameReport` | Render one frame |
| `handleResize` | `(*Renderer, width: u32, height: u32) !void` | Resize swap chain / framebuffer |

---

## Device & Configuration

| Method | Signature | Description |
|--------|-----------|-------------|
| `backendApi` | `(*const Renderer) GraphicsAPI` | Active graphics backend (Metal/Vulkan) |
| `runtimeInfo` | `(*const Renderer) RuntimeInfo` | GPU name, driver, feature flags |
| `vsyncEnabled` | `(*const Renderer) bool` | VSync state |
| `setVSyncEnabled` | `(*Renderer, bool) !void` | Toggle VSync |
| `device` | `(*Renderer) *RhiDevice` | Raw RHI device handle |

---

## Plugin System

| Method | Signature | Description |
|--------|-----------|-------------|
| `styleRegistry` | `(*Renderer) *StyleRegistry` | Render style plugin registry |
| `pluginRegistry` | `(*Renderer) *PluginRegistry` | General plugin registry |
| `discoverPlugins` | `(*Renderer, root_path: []const u8) void` | Scan directory for plugins |
| `enablePlugin` | `(*Renderer, name: []const u8) void` | Activate plugin by name |
| `disablePlugin` | `(*Renderer, name: []const u8) void` | Deactivate plugin |
| `unloadPlugin` | `(*Renderer, name: []const u8) void` | Unload and remove plugin |
| `rescanPlugins` | `(*Renderer, root_path: []const u8) void` | Re-discover + prune stale plugins |
| `tickPluginHotReload` | `(*Renderer) void` | Check for plugin file changes |

---

## Selection & Editor

| Method | Signature | Description |
|--------|-----------|-------------|
| `selectedEntity` | `(*const Renderer) ?EntityId` | First selected entity (or null) |
| `selectedEntities` | `(*const Renderer) []const EntityId` | All selected entities |
| `replaceSelection` | `(*Renderer, ?EntityId) !void` | Set single selection |
| `replaceSelectionMany` | `(*Renderer, []const EntityId) !void` | Set multi-selection |
| `toggleSelection` | `(*Renderer, ?EntityId) !void` | Toggle entity in selection |
| `requestSelectionReadback` | `(*Renderer, ...) void` | Request ID-pass pixel readback |
| `setAiFocusEntities` | `(*Renderer, []const EntityId) void` | Highlight entities for AI focus |
| `clearAiFocusEntities` | `(*Renderer) void` | Clear AI focus highlights |

---

## Editor Viewport

| Method | Signature | Description |
|--------|-----------|-------------|
| `setEditorViewportState` | `(*Renderer, EditorViewportState) void` | Toggle passes (bloom, FXAA, SSAO, DoF, etc.) |
| `setEditorGizmoState` | `(*Renderer, EditorGizmoState) void` | Set gizmo mode / axis |
| `setEditorGizmoTransformOverride` | `(*Renderer, ?Transform) void` | Override gizmo position |
| `setPreviewScene` | `(*Renderer, ?*const Scene) void` | Material preview scene |
| `setCameraPathPreview` | `(*Renderer, []const [3]f32) void` | Visualize camera path |

---

## Scene Viewport

| Method | Signature | Description |
|--------|-----------|-------------|
| `setSceneViewportSize` | `(*Renderer, width: u32, height: u32) !void` | Resize scene viewport |
| `sceneViewportTexture` | `(*Renderer) ?*const Texture` | Final composited texture |
| `sceneViewportSize` | `(*const Renderer) [2]u32` | Current viewport dimensions |
| `passCount` | `(*const Renderer) usize` | Number of active render passes |

---

## Scene State

| Method | Signature | Description |
|--------|-----------|-------------|
| `resetSceneState` | `(*Renderer) !void` | Clear cached scene data |
| `invalidateMainWorldMeshResource` | `(*Renderer, MeshHandle) void` | Mark mesh GPU data stale |
| `invalidateEnvironmentState` | `(*Renderer) void` | Force IBL/skybox rebuild |
| `resetPathTraceState` | `(*Renderer) void` | Restart path tracer accumulation |
| `noteEntityRenderableChanged` | via `World` | Dirty renderable for spatial index |

---

## Path Tracing

| Method | Signature | Description |
|--------|-----------|-------------|
| `pathTraceRenderProgress` | `(*const Renderer) PathTraceRenderProgress` | Sample count, convergence, etc. |
| `exportPathTraceFramePng` | `(*Renderer, allocator, out_path, ...) !void` | Save path-traced image as PNG |
| `exportPathTraceFrameExr` | `(*Renderer, allocator, out_path, ...) !void` | Save path-traced image as EXR |

---

## Material Thumbnails

| Method | Signature | Description |
|--------|-----------|-------------|
| `requestMaterialThumbnail` | `(*Renderer, *Scene, asset_id, frame_index) !void` | Queue thumbnail render |
| `materialThumbnailTexture` | `(*const Renderer, asset_id) ?*const Texture` | Get cached thumbnail |
| `requestMaterialEditorPreview` | `(*Renderer, ...) !void` | Full-size material preview |
| `materialEditorPreviewTexture` | `(*const Renderer) ?*const Texture` | Get preview texture |

---

## Frame Export

| Method | Signature | Description |
|--------|-----------|-------------|
| `downloadFinalFrameAlloc` | `(*Renderer, allocator) ![]u8` | Raw RGBA pixels of last frame |
| `downloadFramePixelsAlloc` | `(*Renderer, allocator) !FramePixels` | Pixels with dimensions |
| `downloadHdrFramePixelsAlloc` | `(*Renderer, allocator) !HdrFramePixels` | HDR (f32) pixel data |
| `downloadHdrFrameExrAlloc` | `(*Renderer, allocator) ![]u8` | Encoded EXR bytes |
| `exportFramePng` | `(*Renderer, allocator, out_path) !void` | Save frame as PNG file |
| `exportFrameExr` | `(*Renderer, allocator, out_path) !void` | Save frame as EXR file |

---

## Preview Entity Filter

| Method | Signature | Description |
|--------|-----------|-------------|
| `setPreviewEntityFilter` | `(*Renderer, []const EntityId) !void` | Only render specified entities |
| `clearPreviewEntityFilter` | `(*Renderer) void` | Render all entities |
| `setPreviewGizmoTransform` | `(*Renderer, ?Transform) void` | Preview gizmo position |

---

## Texture Preview

| Method | Signature | Description |
|--------|-----------|-------------|
| `texturePreviewTexture` | `(*Renderer, ...) ?*const Texture` | Get preview for a texture asset |
