const std = @import("std");
const engine = @import("guava");
const vec3 = engine.math.vec3;

const gravity_y: f32 = 3.8;

pub fn update(layer_context: *engine.core.LayerContext) !void {
    layer_context.world.pruneVfxRuntimeEmitters();

    if (layer_context.playback_controller.state == .stopped) {
        clearAll(layer_context);
        return;
    }
    if (!layer_context.playback_controller.shouldAdvance()) {
        return;
    }

    const allocator = layer_context.world.allocator;
    var emitter_ids = std.ArrayList(engine.scene.EntityId).empty;
    defer emitter_ids.deinit(allocator);

    for (layer_context.world.entities.items) |entity| {
        if (entity.editor_only or entity.vfx == null) {
            continue;
        }
        try emitter_ids.append(allocator, entity.id);
    }

    for (emitter_ids.items) |entity_id| {
        try updateEmitter(layer_context, entity_id);
    }
}

pub fn clearAll(layer_context: *engine.core.LayerContext) void {
    layer_context.world.clearVfxRuntime();
}

pub fn clearEmitterRuntime(layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) void {
    layer_context.world.clearVfxEmitterRuntime(entity_id);
}

fn updateEmitter(layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) !void {
    const entity = layer_context.world.getEntityConst(entity_id) orelse return;
    const vfx = entity.vfx orelse return;
    const emitter = try layer_context.world.ensureVfxRuntimeEmitter(entity_id, vfx);
    const delta = layer_context.delta_seconds;

    emitter.elapsed += delta;
    emitter.emission_accumulator += vfx.emission_rate * delta;

    while (emitter.emission_accumulator >= 1.0 and emitter.particles.len < vfx.max_particles) {
        if (!vfx.looping and emitter.one_shot_remaining == 0) {
            break;
        }
        emitter.emission_accumulator -= 1.0;
        try spawnParticle(layer_context, emitter, entity_id, vfx);
    }

    while (emitter.particles.len > vfx.max_particles) {
        if (emitter.particles.pop()) |particle| {
            destroyParticle(layer_context.world, particle.entity_id);
        }
    }

    var particle_index: usize = 0;
    while (particle_index < emitter.particles.len) {
        var particle = emitter.particles.get(particle_index);
        particle.age += delta;
        if (particle.age >= particle.lifetime) {
            destroyParticle(layer_context.world, particle.entity_id);
            emitter.particles.orderedRemove(particle_index);
            continue;
        }

        switch (vfx.kind) {
            .fountain => updateFountainParticle(&particle, delta),
            .orbit => updateOrbitParticle(&particle, delta, vfx),
        }

        if (layer_context.world.getEntity(particle.entity_id)) |particle_entity| {
            const life_alpha = 1.0 - (particle.age / particle.lifetime);
            const scale_value = std.math.clamp(vfx.size * (0.45 + life_alpha * 0.9), 0.02, 10.0);
            particle_entity.local_transform.translation = particle.position;
            particle_entity.local_transform.scale = .{ scale_value, scale_value, scale_value };
            if (particle_entity.material) |*material| {
                const tint = std.math.clamp(0.65 + life_alpha * 0.35, 0.0, 1.0);
                material.shading = .unlit;
                material.base_color_factor = .{
                    std.math.clamp(vfx.color[0] * tint, 0.0, 1.0),
                    std.math.clamp(vfx.color[1] * tint, 0.0, 1.0),
                    std.math.clamp(vfx.color[2] * tint, 0.0, 1.0),
                    1.0,
                };
            }
        } else {
            emitter.particles.orderedRemove(particle_index);
            continue;
        }

        emitter.particles.set(particle_index, particle);
        particle_index += 1;
    }
}

fn spawnParticle(
    layer_context: *engine.core.LayerContext,
    emitter: *engine.scene.VfxRuntimeEmitter,
    emitter_id: engine.scene.EntityId,
    vfx: engine.scene.Vfx,
) !void {
    const sphere_mesh = try layer_context.world.assets().ensurePrimitiveMesh(.sphere);
    const particle_id = try layer_context.world.createEntity(.{
        .name = "VfxParticle",
        .parent = emitter_id,
        .mesh = .{
            .handle = sphere_mesh,
            .primitive = .sphere,
        },
        .material = .{
            .shading = .unlit,
            .base_color_factor = .{ vfx.color[0], vfx.color[1], vfx.color[2], 1.0 },
        },
        .editor_only = true,
        .local_transform = .{
            .scale = .{ vfx.size, vfx.size, vfx.size },
        },
    });

    const particle = switch (vfx.kind) {
        .fountain => makeFountainParticle(&emitter.seed, particle_id, vfx),
        .orbit => makeOrbitParticle(&emitter.seed, particle_id, vfx),
    };
    try emitter.particles.append(layer_context.world.allocator, particle);
    if (!vfx.looping and emitter.one_shot_remaining > 0) {
        emitter.one_shot_remaining -= 1;
    }
}

fn makeFountainParticle(seed: *u32, entity_id: engine.scene.EntityId, vfx: engine.scene.Vfx) engine.scene.VfxRuntimeParticle {
    const azimuth = nextRandom01(seed) * std.math.tau;
    const radial = nextRandom01(seed) * vfx.spread;
    const start_radius = nextRandom01(seed) * vfx.radius * 0.18;
    const direction = vec3.normalize(.{
        std.math.cos(azimuth) * radial,
        1.0,
        std.math.sin(azimuth) * radial,
    });
    const speed = vfx.speed * (0.72 + nextRandom01(seed) * 0.48);
    return .{
        .entity_id = entity_id,
        .age = 0.0,
        .lifetime = vfx.particle_lifetime * (0.82 + nextRandom01(seed) * 0.36),
        .position = .{
            std.math.cos(azimuth) * start_radius,
            0.0,
            std.math.sin(azimuth) * start_radius,
        },
        .velocity = vec3.scale(direction, speed),
    };
}

fn makeOrbitParticle(seed: *u32, entity_id: engine.scene.EntityId, vfx: engine.scene.Vfx) engine.scene.VfxRuntimeParticle {
    const orbit_radius = vfx.radius * (0.72 + nextRandom01(seed) * 0.55);
    const angle = nextRandom01(seed) * std.math.tau;
    const direction_sign: f32 = if (nextRandom01(seed) > 0.5) 1.0 else -1.0;
    const angular_velocity = (0.8 + nextRandom01(seed) * 1.1) * direction_sign;
    const vertical_offset = (nextRandom01(seed) - 0.5) * vfx.spread;
    const vertical_velocity = (nextRandom01(seed) - 0.5) * 0.12;
    const phase = nextRandom01(seed) * std.math.tau;
    return .{
        .entity_id = entity_id,
        .age = 0.0,
        .lifetime = vfx.particle_lifetime * (0.9 + nextRandom01(seed) * 0.28),
        .position = .{
            std.math.cos(angle) * orbit_radius,
            0.2 + vertical_offset,
            std.math.sin(angle) * orbit_radius,
        },
        .velocity = .{ 0.0, 0.0, 0.0 },
        .orbit_radius = orbit_radius,
        .angular_position = angle,
        .angular_velocity = angular_velocity,
        .vertical_offset = vertical_offset,
        .vertical_velocity = vertical_velocity,
        .phase = phase,
    };
}

fn updateFountainParticle(particle: *engine.scene.VfxRuntimeParticle, delta: f32) void {
    particle.velocity[1] -= gravity_y * delta;
    particle.position = vec3.add(particle.position, vec3.scale(particle.velocity, delta));
    particle.velocity = vec3.scale(particle.velocity, std.math.clamp(1.0 - delta * 0.12, 0.82, 1.0));
}

fn updateOrbitParticle(particle: *engine.scene.VfxRuntimeParticle, delta: f32, vfx: engine.scene.Vfx) void {
    particle.angular_position += particle.angular_velocity * delta * @max(vfx.speed, 0.1);
    particle.vertical_offset += particle.vertical_velocity * delta;
    const bob = std.math.sin((particle.age / particle.lifetime) * std.math.tau + particle.phase) * (0.08 + vfx.spread * 0.3);
    particle.position = .{
        std.math.cos(particle.angular_position) * particle.orbit_radius,
        0.2 + particle.vertical_offset + bob,
        std.math.sin(particle.angular_position) * particle.orbit_radius,
    };
}

fn destroyParticle(world: *engine.scene.World, particle_id: engine.scene.EntityId) void {
    _ = world.destroyEntity(particle_id);
}

fn nextRandom01(seed: *u32) f32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return @as(f32, @floatFromInt(seed.* >> 8)) / 16_777_215.0;
}

test "orbit particle update keeps particle on a ring" {
    var particle = engine.scene.VfxRuntimeParticle{
        .entity_id = 1,
        .age = 0.2,
        .lifetime = 1.5,
        .position = .{ 0.6, 0.2, 0.0 },
        .velocity = .{ 0.0, 0.0, 0.0 },
        .orbit_radius = 0.6,
        .angular_position = 0.0,
        .angular_velocity = 1.0,
    };
    const vfx = engine.scene.Vfx{
        .kind = .orbit,
        .radius = 0.6,
        .spread = 0.15,
        .speed = 1.0,
    };
    updateOrbitParticle(&particle, 0.1, vfx);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), std.math.sqrt(particle.position[0] * particle.position[0] + particle.position[2] * particle.position[2]), 0.08);
}
