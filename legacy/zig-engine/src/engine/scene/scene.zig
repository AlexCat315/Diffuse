const world_mod = @import("world.zig");

pub const Scene = world_mod.World;
pub const World = world_mod.World;
pub const EntityId = world_mod.EntityId;
pub const Entity = world_mod.Entity;
pub const EntityDesc = world_mod.EntityDesc;
pub const Summary = world_mod.Summary;
pub const Ray = @import("raycast.zig").Ray;
pub const SurfaceRaycastHit = @import("raycast.zig").SurfaceRaycastHit;
pub const Rigidbody = @import("components.zig").Rigidbody;
pub const RigidbodyMotionType = @import("components.zig").RigidbodyMotionType;
pub const BoxCollider = @import("components.zig").BoxCollider;
pub const SphereCollider = @import("components.zig").SphereCollider;
pub const MeshCollider = @import("components.zig").MeshCollider;
pub const Vfx = @import("components.zig").Vfx;
pub const VfxKind = @import("components.zig").VfxKind;
pub const VfxRuntimeParticle = @import("vfx_runtime.zig").VfxRuntimeParticle;
pub const VfxRuntimeEmitter = @import("vfx_runtime.zig").VfxRuntimeEmitter;
pub const AudioBus = @import("components.zig").AudioBus;
pub const AudioSource = @import("components.zig").AudioSource;
pub const AudioListener = @import("components.zig").AudioListener;
pub const SceneRuntimeState = @import("scene_io.zig").SceneRuntimeState;
pub const serializeWorldAlloc = @import("scene_io.zig").serializeWorldAlloc;
pub const serializeWorldWithRuntimeStateAlloc = @import("scene_io.zig").serializeWorldWithRuntimeStateAlloc;
pub const deserializeWorldFromSlice = @import("scene_io.zig").deserializeWorldFromSlice;
pub const deserializeWorldWithRuntimeStateFromSlice = @import("scene_io.zig").deserializeWorldWithRuntimeStateFromSlice;
pub const saveWorldToPath = @import("scene_io.zig").saveWorldToPath;
pub const saveWorldWithRuntimeStateToPath = @import("scene_io.zig").saveWorldWithRuntimeStateToPath;
pub const loadWorldFromPath = @import("scene_io.zig").loadWorldFromPath;
pub const loadWorldWithRuntimeStateFromPath = @import("scene_io.zig").loadWorldWithRuntimeStateFromPath;

test {
    _ = @import("world.zig");
    _ = @import("raycast.zig");
    _ = @import("scene_io.zig");
    _ = @import("vfx_runtime.zig");
    _ = @import("../physics/system.zig");
}
