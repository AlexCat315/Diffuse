# Scene / ECS API

> Source: [`src/engine/scene/world.zig`](../../src/engine/scene/world.zig),
> [`src/engine/scene/components.zig`](../../src/engine/scene/components.zig)

## Overview

The scene system uses an ECS-style architecture where:
- **World** — the root container managing all entities
- **Entity** — an object identified by `EntityId` with optional components
- **Components** — plain data structs attached to entities (Transform, Mesh, Light, etc.)

---

## World

### Lifecycle

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `(allocator, ?*JobSystem) World` | Create a new empty world |
| `deinit` | `(*World) void` | Destroy world and all entities |
| `clear` | `(*World) void` | Remove all entities (keep allocator) |

### Entity Management

| Method | Signature | Description |
|--------|-----------|-------------|
| `createEntity` | `(*World, EntityDesc) !EntityId` | Create entity from descriptor |
| `createEntityWithId` | `(*World, EntityId, EntityDesc) !EntityId` | Create with explicit ID |
| `destroyEntity` | `(*World, EntityId) bool` | Remove entity and children |
| `duplicateEntity` | `(*World, EntityId) !EntityId` | Deep-copy entity subtree |
| `getEntity` | `(*World, EntityId) ?*Entity` | Mutable entity lookup |
| `getEntityConst` | `(*const World, EntityId) ?*const Entity` | Immutable entity lookup |
| `hasEntity` | `(*const World, EntityId) bool` | Existence check |
| `findEntityByName` | `(*const World, []const u8) ?*const Entity` | Lookup by name string |
| `renameEntity` | `(*World, EntityId, []const u8) !bool` | Change entity name |
| `setEntityVisible` | `(*World, EntityId, bool) bool` | Toggle visibility |
| `nextAvailableName` | `(*const World, []const u8) ![]u8` | Generate unique name (e.g. "Cube_2") |

### Hierarchy

| Method | Signature | Description |
|--------|-----------|-------------|
| `setParent` | `(*World, child: EntityId, parent: ?EntityId) !bool` | Reparent (preserves world transform) |
| `setParentLocal` | `(*World, child: EntityId, parent: ?EntityId) !bool` | Reparent (preserves local transform) |
| `parentEntity` | `(*const World, EntityId) ?EntityId` | Get parent ID |
| `markDirty` | `(*World, EntityId) void` | Mark transform dirty (propagates to children) |
| `updateHierarchy` | `(*World) void` | Recompute world transforms + bounds + spatial index |

### Transform

| Method | Signature | Description |
|--------|-----------|-------------|
| `setEntityLocalTransform` | `(*World, EntityId, Transform) bool` | Set local TRS |
| `localTransform` | `(*const World, EntityId) Transform` | Get local TRS |
| `worldTransform` | `(*World, EntityId) ?Transform` | Get world-space TRS |
| `worldTransformConst` | `(*const World, EntityId) ?Transform` | Get world-space TRS (const) |
| `setEntityWorldTransform` | `(*World, EntityId, Transform) bool` | Set world TRS (computes local) |
| `worldBounds` | `(*World, EntityId) ?AABB` | World-space bounding box |

### Physics Components

| Method | Signature | Description |
|--------|-----------|-------------|
| `getRigidbody` / `setRigidbody` | `EntityId` ↔ `Rigidbody` | Rigidbody access |
| `hasRigidbody` | `(*const World, EntityId) bool` | Check presence |
| `getBoxCollider` / `setBoxCollider` | `EntityId` ↔ `BoxCollider` | Box collider access |
| `getSphereCollider` / `setSphereCollider` | `EntityId` ↔ `SphereCollider` | Sphere collider access |

### Camera

| Method | Signature | Description |
|--------|-----------|-------------|
| `primaryCameraEntity` | `(*const World) ?EntityId` | Get active camera entity |
| `setPrimaryCamera` | `(*World, EntityId) bool` | Set the primary camera |

### Spatial Queries

| Method | Signature | Description |
|--------|-----------|-------------|
| `raycastSurface` | `(*World, Ray) ?SurfaceRaycastHit` | Ray-against-scene query |
| `queryRenderableRayCandidates` | `(*World, Ray, ...) []RenderableRayCandidate` | BVH ray candidates |
| `queryRenderableFrustumCandidates` | `(*World, Frustum, ...) []EntityId` | Frustum culling |

### Animation

| Method | Signature | Description |
|--------|-----------|-------------|
| `bindAnimatorTargets` | `(*World, EntityId, []const EntityId) !void` | Bind skeleton targets |
| `animatorTargets` | `(*const World, EntityId) ?[]const EntityId` | Get bound targets |
| `bindAnimatorGraph` | `(*World, EntityId, *AnimationGraph, ...) !void` | Attach animation graph |
| `clearAnimatorGraph` | `(*World, EntityId) bool` | Detach animation graph |
| `setAnimatorGraphParameter` | `(*World, EntityId, idx, value) void` | Set graph parameter |

### Prefab System

| Method | Signature | Description |
|--------|-----------|-------------|
| `createPrefab` | `(*World, EntityId, []const u8) !void` | Create prefab from entity tree |
| `loadPrefab` | `(*World, path) !PrefabId` | Load prefab from file |
| `savePrefab` | `(*World, id, path) !void` | Save prefab to file |
| `instantiatePrefab` | `(*World, prefab_id, options) !EntityId` | Spawn prefab instance |
| `getPrefab` | `(*const World, id) ?*PrefabResource` | Lookup loaded prefab |
| `removePrefab` | `(*World, id) !void` | Unload prefab |
| `updatePrefabInstance` | `(*World, EntityId, prefab_id) !void` | Sync instance to latest |
| `updateAllPrefabInstances` | `(*World, prefab_id) !usize` | Batch update all instances |
| `revertPrefabOverride` | `(*World, EntityId) !void` | Revert instance overrides |

### Import

| Method | Signature | Description |
|--------|-----------|-------------|
| `importGltfStaticModel` | `(*World, ...) !EntityId` | Import glTF model synchronously |
| `importGltfAsync` | `(*World, ...) !void` | Import glTF model via job system |

### Misc

| Method | Signature | Description |
|--------|-----------|-------------|
| `sceneRevision` | `(*const World) u64` | Monotonic revision counter |
| `markSceneChanged` | `(*World) void` | Bump revision manually |
| `summary` | `(*const World) Summary` | Entity/component count summary |
| `assets` | `(*World) *ResourceLibrary` | Access asset library |

---

## Components

All components are plain `struct` types defined in `components.zig`.

### Transform

```zig
pub const Transform = struct {
    translation: Vec3 = .{ 0, 0, 0 },
    rotation: Quat = .{ 0, 0, 0, 1 },  // XYZW identity
    scale: Vec3 = .{ 1, 1, 1 },

    pub fn identity() Transform;
    pub fn toMatrix(self: Transform) [16]f32;  // T * R * S
};
```

### Camera

```zig
pub const CameraProjection = union(enum) {
    perspective: struct { fov_y_radians: f32 = 1.047, near_clip: f32 = 0.1, far_clip: f32 = 1000.0 },
    orthographic: struct { size: f32 = 10.0, near_clip: f32 = -1.0, far_clip: f32 = 1.0 },
};

pub const Camera = struct {
    projection: CameraProjection = .{ .perspective = .{} },
    is_primary: bool = false,
};
```

### Mesh & SkinnedMesh

```zig
pub const Primitive = enum { cube, sphere, plane, custom };

pub const Mesh = struct {
    handle: ?MeshHandle = null,
    primitive: Primitive = .custom,
};

pub const SkinnedMesh = struct {
    mesh_handle: ?MeshHandle = null,
    primitive: Primitive = .custom,
    skeleton_handle: ?SkeletonHandle = null,
    skin_handle: ?SkinHandle = null,
};
```

### Material

```zig
pub const ShadingModel = enum { unlit, lambert, pbr_metallic_roughness };

pub const Material = struct {
    handle: ?MaterialHandle = null,
    shading: ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1, 1, 1, 1 },
    emissive_factor: [3]f32 = .{ 0, 0, 0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
};
```

### Light

```zig
pub const LightKind = enum { directional, point, spot };

pub const Light = struct {
    kind: LightKind = .directional,
    color: Vec3 = .{ 1, 1, 1 },
    intensity: f32 = 1.0,
    range: f32 = 10.0,       // point/spot only
};
```

### Physics

```zig
pub const RigidbodyMotionType = enum { static, dynamic, kinematic };

pub const Rigidbody = struct {
    motion_type: RigidbodyMotionType = .dynamic,
    mass: f32 = 1.0,
    linear_velocity: Vec3 = .{ 0, 0, 0 },
    angular_velocity: Vec3 = .{ 0, 0, 0 },
    gravity_scale: f32 = 1.0,
    linear_damping: f32 = 0.04,
    angular_damping: f32 = 0.04,
    allow_sleep: bool = true,
};

pub const BoxCollider = struct {
    half_extents: Vec3 = .{ 0.5, 0.5, 0.5 },
    center: Vec3 = .{ 0, 0, 0 },
    is_trigger: bool = false,
    layer_id: u16 = 0,
    layer_group: u16 = 0xFFFF,
};

pub const SphereCollider = struct {
    radius: f32 = 0.5,
    center: Vec3 = .{ 0, 0, 0 },
    is_trigger: bool = false,
    layer_id: u16 = 0,
    layer_group: u16 = 0xFFFF,
};

pub const MeshCollider = struct {
    use_attached_mesh: bool = true,
    is_trigger: bool = false,
    layer_id: u16 = 0,
    layer_group: u16 = 0xFFFF,
};

pub const ConstraintType = enum(u8) { point_to_point, hinge, slider, distance };

pub const Constraint = struct {
    constraint_type: ConstraintType = .point_to_point,
    entity_a: EntityId,
    entity_b: EntityId,
    pivot_a: Vec3 = .{ 0, 0, 0 },
    pivot_b: Vec3 = .{ 0, 0, 0 },
    axis_a: Vec3 = .{ 0, 1, 0 },
    axis_b: Vec3 = .{ 0, 1, 0 },
    min_limit: f32 = 0.0,
    max_limit: f32 = 0.0,
    is_enabled: bool = true,
};
```

### Animator

```zig
pub const Animator = struct {
    skeleton_handle: ?SkeletonHandle = null,
    default_clip_handle: ?AnimationClipHandle = null,
    time_seconds: f32 = 0.0,
    speed: f32 = 1.0,
    playing: bool = true,
    looping: bool = true,
    // ... blend fields for crossfade
};
```

### VFX (Particles)

```zig
pub const VfxKind = enum { fountain, orbit };

pub const Vfx = struct {
    kind: VfxKind = .fountain,
    looping: bool = true,
    emission_rate: f32 = 18.0,
    particle_lifetime: f32 = 1.25,
    speed: f32 = 2.2,
    max_particles: u16 = 24,
    radius: f32 = 0.55,
    spread: f32 = 0.35,
    size: f32 = 0.12,
    color: Vec3 = .{ 1.0, 0.58, 0.26 },
};
```

### Script

```zig
pub const ScriptLanguage = enum(u8) { zig, csharp };

pub const Script = struct {
    script_handle: ?ScriptHandle = null,
    language: ScriptLanguage = .zig,
    instance_id: ?u64 = null,
    enabled: bool = true,
    parameters: []const u8 = &.{},
};
```

### Audio

```zig
pub const AudioBus = enum(u8) { master = 0, music = 1, sfx = 2 };

pub const AudioSource = struct {
    clip_handle: ?AudioClipHandle = null,
    clip_asset_path: ?[]const u8 = null,
    bus: AudioBus = .sfx,
    volume: f32 = 1.0,
    spatial: bool = false,
    looping: bool = false,
    play_on_awake: bool = true,
    min_distance: f32 = 1.0,
    max_distance: f32 = 100.0,
    doppler_factor: f32 = 1.0,
};

pub const AudioListener = struct {
    enabled: bool = true,
};
```

### Navigation

```zig
pub const NavAgent = struct {
    radius: f32 = 0.6,
    height: f32 = 2.0,
    max_acceleration: f32 = 8.0,
    max_speed: f32 = 3.5,
    target: ?Vec3 = null,
};
```
