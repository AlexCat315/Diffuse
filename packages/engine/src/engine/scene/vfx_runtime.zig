const std = @import("std");

pub const VfxRuntimeParticle = struct {
    entity_id: u64,
    age: f32,
    lifetime: f32,
    position: [3]f32,
    velocity: [3]f32,
    orbit_radius: f32 = 0.0,
    angular_position: f32 = 0.0,
    angular_velocity: f32 = 0.0,
    vertical_offset: f32 = 0.0,
    vertical_velocity: f32 = 0.0,
    phase: f32 = 0.0,
};

pub const VfxRuntimeParticleList = std.MultiArrayList(VfxRuntimeParticle);

pub const VfxRuntimeEmitter = struct {
    entity_id: u64,
    seed: u32 = 0,
    elapsed: f32 = 0.0,
    emission_accumulator: f32 = 0.0,
    one_shot_remaining: u16 = 0,
    particles: VfxRuntimeParticleList = .empty,

    pub fn deinit(self: *VfxRuntimeEmitter, allocator: std.mem.Allocator) void {
        self.particles.deinit(allocator);
        self.* = undefined;
    }
};
