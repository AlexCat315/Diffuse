# Guava Engine API Reference

> Auto-maintained documentation for the Guava Engine public API.
> Source of truth: `src/` — keep this in sync when APIs change.

## Modules

| Document | Source | Description |
|----------|--------|-------------|
| [Script API](script-api.md) | `src/engine/script/script_api.zig` | `@import("guava")` — user-facing dylib script API |
| [Scene / ECS](scene-ecs.md) | `src/engine/scene/world.zig`, `components.zig` | World, Entity, Component types |
| [Renderer](renderer.md) | `src/engine/render/renderer.zig` | Rendering pipeline, passes, export |

## Conventions

- **EntityId** — `u32`, unique per-World identifier for an entity.
- **Handle types** — opaque `u32` indices into asset registries (`MeshHandle`, `MaterialHandle`, etc.).
- **Transforms** — `{ translation: Vec3, rotation: Quat, scale: Vec3 }`. Quat is XYZW.
- **Coordinate system** — right-handed, Y-up.
- **Error handling** — functions return `!T` (error union) or `?T` (optional). Callers should `try` or `catch`.
