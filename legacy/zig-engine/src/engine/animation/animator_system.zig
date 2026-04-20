const std = @import("std");
const animation_graph_mod = @import("animation_graph.zig");
const animation_clip_mod = @import("../assets/animation_clip_resource.zig");
const handles = @import("../assets/handles.zig");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const quat = @import("../math/quat.zig");

pub const PlayClipOptions = struct {
    blend_duration_seconds: f32 = 0.0,
    reset_time: bool = true,
};

pub const PlayClipError = error{
    EntityNotFound,
    MissingAnimator,
};

const PlaybackState = struct {
    sampled_time: f32,
    finished: bool = false,
};

const ClipSample = struct {
    clip: *const animation_clip_mod.AnimationClipResource,
    time: f32,
};

const AnimatorPoseState = struct {
    primary: ClipSample,
    secondary: ?ClipSample = null,
    blend_factor: f32 = 0.0,
};

pub fn update(world: *world_mod.World, delta_seconds: f32) void {
    if (delta_seconds <= 0.0) {
        return;
    }

    var entity_index: usize = 0;
    while (entity_index < world.entities.items.len) : (entity_index += 1) {
        const entity_id = world.entities.items[entity_index].id;
        const animator_value = world.entities.items[entity_index].animator orelse continue;
        if (!animator_value.playing) {
            continue;
        }

        const targets = world.animatorTargets(entity_id) orelse continue;
        const base_transforms = world.animatorBaseTransforms(entity_id) orelse continue;

        var next_animator = animator_value;
        if (resolvePoseState(world, entity_id, &next_animator, delta_seconds)) |pose_state| {
            applyPose(world, targets, base_transforms, pose_state);
        }
        world.entities.items[entity_index].animator = next_animator;
    }
}

/// 在编辑器中按指定时间点采样并预览动画，不推进动画系统时间。
/// 用于动画编辑器的 Play/Pause 和时间轴拖拽预览。
pub fn sampleEntityAtTime(
    world: *world_mod.World,
    entity_id: world_mod.EntityId,
    clip_handle: handles.AnimationClipHandle,
    time: f32,
) void {
    const clip = world.resources.animationClip(clip_handle) orelse return;
    const targets = world.animatorTargets(entity_id) orelse return;
    const base_transforms = world.animatorBaseTransforms(entity_id) orelse return;
    applyPose(world, targets, base_transforms, .{
        .primary = .{ .clip = clip, .time = time },
    });
}

pub fn playClip(
    world: *world_mod.World,
    animator_entity_id: world_mod.EntityId,
    clip_handle: handles.AnimationClipHandle,
    options: PlayClipOptions,
) PlayClipError!void {
    _ = world.clearAnimatorGraph(animator_entity_id);
    const entity = world.getEntity(animator_entity_id) orelse return error.EntityNotFound;
    const animator = entity.animator orelse return error.MissingAnimator;

    var next_animator = animator;
    if (options.blend_duration_seconds <= 0.0001 or
        next_animator.default_clip_handle == null or
        next_animator.default_clip_handle.? == clip_handle)
    {
        next_animator.default_clip_handle = clip_handle;
        if (options.reset_time or animator.default_clip_handle != clip_handle) {
            next_animator.time_seconds = 0.0;
        }
        next_animator.next_clip_handle = null;
        next_animator.next_time_seconds = 0.0;
        next_animator.blend_duration_seconds = 0.0;
        next_animator.blend_time_seconds = 0.0;
        next_animator.playing = true;
        entity.animator = next_animator;
        return;
    }

    next_animator.next_clip_handle = clip_handle;
    next_animator.next_time_seconds = if (options.reset_time or next_animator.next_clip_handle != clip_handle)
        0.0
    else
        next_animator.next_time_seconds;
    next_animator.blend_duration_seconds = options.blend_duration_seconds;
    next_animator.blend_time_seconds = 0.0;
    next_animator.playing = true;
    entity.animator = next_animator;
}

fn resolvePoseState(
    world: *world_mod.World,
    animator_entity_id: world_mod.EntityId,
    animator: *components.Animator,
    delta_seconds: f32,
) ?AnimatorPoseState {
    if (world.animatorGraphInstance(animator_entity_id) != null) {
        return resolveGraphPoseState(world, animator_entity_id, animator, delta_seconds);
    }
    return resolveClipPoseState(world, animator, delta_seconds);
}

fn resolveClipPoseState(
    world: *world_mod.World,
    animator: *components.Animator,
    delta_seconds: f32,
) ?AnimatorPoseState {
    const clip_handle = animator.default_clip_handle orelse return null;
    const clip = world.resources.animationClip(clip_handle) orelse return null;

    const scaled_delta = delta_seconds * animator.speed;
    animator.time_seconds += scaled_delta;
    const primary_state = resolvePlaybackTimeState(animator.looping, animator.speed, &animator.time_seconds, clip.duration);

    if (animator.next_clip_handle) |next_handle| {
        const next_clip = world.resources.animationClip(next_handle) orelse {
            animator.next_clip_handle = null;
            animator.next_time_seconds = 0.0;
            animator.blend_duration_seconds = 0.0;
            animator.blend_time_seconds = 0.0;
            if (primary_state.finished) {
                animator.playing = false;
            }
            return .{
                .primary = .{ .clip = clip, .time = primary_state.sampled_time },
            };
        };

        animator.next_time_seconds += scaled_delta;
        const secondary_state = resolvePlaybackTimeState(animator.looping, animator.speed, &animator.next_time_seconds, next_clip.duration);
        animator.blend_time_seconds += delta_seconds;

        const blend_factor = std.math.clamp(
            if (animator.blend_duration_seconds <= 0.0001)
                1.0
            else
                animator.blend_time_seconds / animator.blend_duration_seconds,
            0.0,
            1.0,
        );

        if (blend_factor >= 0.9999) {
            animator.default_clip_handle = next_handle;
            animator.time_seconds = secondary_state.sampled_time;
            animator.next_clip_handle = null;
            animator.next_time_seconds = 0.0;
            animator.blend_duration_seconds = 0.0;
            animator.blend_time_seconds = 0.0;
            animator.playing = !secondary_state.finished;
            return .{
                .primary = .{ .clip = next_clip, .time = secondary_state.sampled_time },
            };
        }

        return .{
            .primary = .{ .clip = clip, .time = primary_state.sampled_time },
            .secondary = .{ .clip = next_clip, .time = secondary_state.sampled_time },
            .blend_factor = blend_factor,
        };
    }

    if (primary_state.finished) {
        animator.playing = false;
    }

    return .{
        .primary = .{ .clip = clip, .time = primary_state.sampled_time },
    };
}

fn resolveGraphPoseState(
    world: *world_mod.World,
    animator_entity_id: world_mod.EntityId,
    animator: *components.Animator,
    delta_seconds: f32,
) ?AnimatorPoseState {
    const instance = world.animatorGraphInstance(animator_entity_id) orelse return null;
    instance.update(delta_seconds * @max(animator.speed, 0.0));

    const runtime = instance.runtimeClipBlend();
    syncGraphAnimatorSnapshot(animator, runtime);
    const runtime_blend = runtime orelse return null;

    const primary = resolveGraphClipSample(world, runtime_blend.primary) orelse return null;
    var pose_state = AnimatorPoseState{
        .primary = primary,
    };

    if (runtime_blend.secondary) |secondary_state| {
        if (resolveGraphClipSample(world, secondary_state)) |secondary| {
            pose_state.secondary = secondary;
            pose_state.blend_factor = runtime_blend.blend_factor;
        }
    }

    return pose_state;
}

fn resolvePlaybackTime(animator: *components.Animator, duration: f32) f32 {
    const state = resolvePlaybackTimeState(animator.looping, animator.speed, &animator.time_seconds, duration);
    if (state.finished) {
        animator.playing = false;
    }
    return state.sampled_time;
}

fn resolvePlaybackTimeState(looping: bool, speed: f32, time_seconds: *f32, duration: f32) PlaybackState {
    if (duration <= 0.0001) {
        time_seconds.* = 0.0;
        return .{ .sampled_time = 0.0, .finished = true };
    }

    if (looping) {
        time_seconds.* = wrapTime(time_seconds.*, duration);
        return .{ .sampled_time = time_seconds.* };
    }

    if (time_seconds.* <= 0.0) {
        time_seconds.* = 0.0;
        return .{ .sampled_time = 0.0, .finished = speed < 0.0 };
    }
    if (time_seconds.* >= duration) {
        time_seconds.* = duration;
        return .{ .sampled_time = duration, .finished = speed >= 0.0 };
    }

    return .{ .sampled_time = time_seconds.* };
}

fn wrapTime(time_seconds: f32, duration: f32) f32 {
    var wrapped = @mod(time_seconds, duration);
    if (wrapped < 0.0) {
        wrapped += duration;
    }
    return wrapped;
}

fn resolveGraphClipSample(
    world: *world_mod.World,
    runtime_state: animation_graph_mod.RuntimeClipState,
) ?ClipSample {
    const clip_handle = runtime_state.clip_handle orelse return null;
    const clip = world.resources.animationClip(clip_handle) orelse return null;
    return .{
        .clip = clip,
        .time = runtime_state.sample_time,
    };
}

fn syncGraphAnimatorSnapshot(
    animator: *components.Animator,
    runtime: ?animation_graph_mod.RuntimeClipBlend,
) void {
    const runtime_blend = runtime orelse {
        animator.default_clip_handle = null;
        animator.time_seconds = 0.0;
        animator.next_clip_handle = null;
        animator.next_time_seconds = 0.0;
        animator.blend_duration_seconds = 0.0;
        animator.blend_time_seconds = 0.0;
        animator.playing = false;
        return;
    };

    animator.default_clip_handle = runtime_blend.primary.clip_handle;
    animator.time_seconds = runtime_blend.primary.sample_time;
    if (runtime_blend.secondary) |secondary| {
        animator.next_clip_handle = secondary.clip_handle;
        animator.next_time_seconds = secondary.sample_time;
        animator.blend_duration_seconds = runtime_blend.transition_duration;
        animator.blend_time_seconds = runtime_blend.transition_time;
    } else {
        animator.next_clip_handle = null;
        animator.next_time_seconds = 0.0;
        animator.blend_duration_seconds = 0.0;
        animator.blend_time_seconds = 0.0;
    }
    animator.playing = true;
}

fn applyPose(
    world: *world_mod.World,
    targets: []const world_mod.EntityId,
    base_transforms: []const components.Transform,
    pose_state: AnimatorPoseState,
) void {
    for (targets, 0..) |target_id, target_index| {
        const entity = world.getEntity(target_id) orelse continue;
        const base_transform = if (target_index < base_transforms.len) base_transforms[target_index] else entity.local_transform;
        const primary_transform = sampleClipTransform(
            pose_state.primary.clip,
            @intCast(target_index),
            base_transform,
            pose_state.primary.time,
        );
        const final_transform = if (pose_state.secondary) |secondary|
            blendTransform(
                primary_transform,
                sampleClipTransform(secondary.clip, @intCast(target_index), base_transform, secondary.time),
                pose_state.blend_factor,
            )
        else
            primary_transform;

        if (!std.meta.eql(entity.local_transform, final_transform)) {
            entity.local_transform = final_transform;
            world.markDirty(entity.id);
        }
    }
}

fn sampleClipTransform(
    clip: *const animation_clip_mod.AnimationClipResource,
    target_index: u32,
    base_transform: components.Transform,
    sample_time: f32,
) components.Transform {
    var transform = base_transform;

    if (findVec3Track(clip.translation_tracks, target_index)) |track| {
        transform.translation = sampleVec3Track(track.interpolation, track.times, track.values, sample_time);
    }
    if (findQuatTrack(clip.rotation_tracks, target_index)) |track| {
        transform.rotation = sampleQuatTrack(track.interpolation, track.times, track.values, sample_time);
    }
    if (findVec3Track(clip.scale_tracks, target_index)) |track| {
        transform.scale = sampleVec3Track(track.interpolation, track.times, track.values, sample_time);
    }

    return transform;
}

fn findVec3Track(
    tracks: []const animation_clip_mod.Vec3Track,
    target_index: u32,
) ?*const animation_clip_mod.Vec3Track {
    for (tracks) |*track| {
        if (track.target_entity_index == target_index) {
            return track;
        }
    }
    return null;
}

fn findQuatTrack(
    tracks: []const animation_clip_mod.QuatTrack,
    target_index: u32,
) ?*const animation_clip_mod.QuatTrack {
    for (tracks) |*track| {
        if (track.target_entity_index == target_index) {
            return track;
        }
    }
    return null;
}

fn sampleVec3Track(
    interpolation: animation_clip_mod.Interpolation,
    times: []const f32,
    values: []const [3]f32,
    sample_time: f32,
) [3]f32 {
    if (times.len == 0 or values.len == 0) {
        return .{ 0.0, 0.0, 0.0 };
    }
    if (times.len == 1 or sample_time <= times[0]) {
        return values[0];
    }

    const last_index = times.len - 1;
    if (sample_time >= times[last_index]) {
        return values[last_index];
    }

    const segment = findTrackSegment(times, sample_time);
    const start_time = times[segment];
    const end_time = times[segment + 1];
    const t = if (@abs(end_time - start_time) <= 0.00001) 0.0 else (sample_time - start_time) / (end_time - start_time);

    return switch (interpolation) {
        .step => values[segment],
        .linear, .cubic_spline => lerpVec3(values[segment], values[segment + 1], t),
    };
}

fn sampleQuatTrack(
    interpolation: animation_clip_mod.Interpolation,
    times: []const f32,
    values: []const [4]f32,
    sample_time: f32,
) [4]f32 {
    if (times.len == 0 or values.len == 0) {
        return quat.identity();
    }
    if (times.len == 1 or sample_time <= times[0]) {
        return quat.normalize(values[0]);
    }

    const last_index = times.len - 1;
    if (sample_time >= times[last_index]) {
        return quat.normalize(values[last_index]);
    }

    const segment = findTrackSegment(times, sample_time);
    const start_time = times[segment];
    const end_time = times[segment + 1];
    const t = if (@abs(end_time - start_time) <= 0.00001) 0.0 else (sample_time - start_time) / (end_time - start_time);

    return switch (interpolation) {
        .step => quat.normalize(values[segment]),
        .linear, .cubic_spline => slerpQuat(values[segment], values[segment + 1], t),
    };
}

fn findTrackSegment(times: []const f32, sample_time: f32) usize {
    var index: usize = 0;
    while (index + 1 < times.len) : (index += 1) {
        if (sample_time < times[index + 1]) {
            return index;
        }
    }
    return times.len - 2;
}

fn lerpVec3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        std.math.lerp(a[0], b[0], t),
        std.math.lerp(a[1], b[1], t),
        std.math.lerp(a[2], b[2], t),
    };
}

fn slerpQuat(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var qa = quat.normalize(a);
    var qb = quat.normalize(b);
    var dot_value = qa[0] * qb[0] + qa[1] * qb[1] + qa[2] * qb[2] + qa[3] * qb[3];

    if (dot_value < 0.0) {
        qb = .{ -qb[0], -qb[1], -qb[2], -qb[3] };
        dot_value = -dot_value;
    }

    if (dot_value > 0.9995) {
        qa = .{
            std.math.lerp(qa[0], qb[0], t),
            std.math.lerp(qa[1], qb[1], t),
            std.math.lerp(qa[2], qb[2], t),
            std.math.lerp(qa[3], qb[3], t),
        };
        return quat.normalize(qa);
    }

    const theta_0 = std.math.acos(std.math.clamp(dot_value, -1.0, 1.0));
    const theta = theta_0 * t;
    const sin_theta = std.math.sin(theta);
    const sin_theta_0 = std.math.sin(theta_0);

    const s0 = std.math.cos(theta) - dot_value * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;
    return .{
        qa[0] * s0 + qb[0] * s1,
        qa[1] * s0 + qb[1] * s1,
        qa[2] * s0 + qb[2] * s1,
        qa[3] * s0 + qb[3] * s1,
    };
}

fn blendTransform(a: components.Transform, b: components.Transform, factor: f32) components.Transform {
    return .{
        .translation = lerpVec3(a.translation, b.translation, factor),
        .rotation = slerpQuat(a.rotation, b.rotation, factor),
        .scale = lerpVec3(a.scale, b.scale, factor),
    };
}

test "animator system samples translation and looping time" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{
        .name = "Bone",
    });
    const animator_id = try world.createEntity(.{
        .name = "Animator",
        .animator = .{
            .default_clip_handle = undefined,
        },
    });

    const clip_handle = try world.resources.createAnimationClip(.{
        .name = "Move",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 2.0, 0.0, 0.0 } },
            },
        },
    });
    world.getEntity(animator_id).?.animator.?.default_clip_handle = clip_handle;
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    update(&world, 0.5);
    const target = world.getEntityConst(target_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), target.local_transform.translation[0], 0.0001);

    update(&world, 0.75);
    const animator = world.getEntityConst(animator_id).?.animator.?;
    try std.testing.expect(animator.time_seconds < 1.0);
}

test "animator system stops non-looping clips at the end" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{ .name = "Target" });
    const clip_handle = try world.resources.createAnimationClip(.{
        .name = "Rotate",
        .duration = 0.5,
        .rotation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 0.5 },
                .values = &.{ .{ 0.0, 0.0, 0.0, 1.0 }, .{ 0.0, 0.70710677, 0.0, 0.70710677 } },
            },
        },
    });
    const animator_id = try world.createEntity(.{
        .name = "Animator",
        .animator = .{
            .default_clip_handle = clip_handle,
            .looping = false,
        },
    });
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    update(&world, 1.0);
    const animator = world.getEntityConst(animator_id).?.animator.?;
    const target = world.getEntityConst(target_id).?;
    try std.testing.expect(!animator.playing);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710677), target.local_transform.rotation[1], 0.0001);
}

test "animator system cross-fades between clips" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{
        .name = "Target",
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });
    const clip_a = try world.resources.createAnimationClip(.{
        .name = "Idle",
        .duration = 2.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 2.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } },
            },
        },
    });
    const clip_b = try world.resources.createAnimationClip(.{
        .name = "Move",
        .duration = 2.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 2.0 },
                .values = &.{ .{ 10.0, 0.0, 0.0 }, .{ 10.0, 0.0, 0.0 } },
            },
        },
    });
    const animator_id = try world.createEntity(.{
        .name = "Animator",
        .animator = .{
            .default_clip_handle = clip_a,
        },
    });
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    try playClip(&world, animator_id, clip_b, .{ .blend_duration_seconds = 1.0 });
    update(&world, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), world.getEntityConst(target_id).?.local_transform.translation[0], 0.0001);

    update(&world, 0.6);
    const animator = world.getEntityConst(animator_id).?.animator.?;
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, clip_b), animator.default_clip_handle);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, null), animator.next_clip_handle);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), world.getEntityConst(target_id).?.local_transform.translation[0], 0.0001);
}

test "animator system evaluates bound animation graph transitions" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{ .name = "GraphTarget" });
    const clip_a = try world.resources.createAnimationClip(.{
        .name = "Idle",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } },
            },
        },
    });
    const clip_b = try world.resources.createAnimationClip(.{
        .name = "Run",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 10.0, 0.0, 0.0 }, .{ 10.0, 0.0, 0.0 } },
            },
        },
    });
    const animator_id = try world.createEntity(.{
        .name = "GraphAnimator",
        .animator = .{},
    });
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    var graph = try animation_graph_mod.AnimationGraph.init(std.testing.allocator, "GraphAnimator");
    defer graph.deinit();
    const idle = try graph.addState("Idle", clip_a);
    const run = try graph.addState("Run", clip_b);
    graph.default_state = idle;
    const conditions = [_]animation_graph_mod.TransitionCondition{
        .{ .time_elapsed = 0.0 },
    };
    try graph.addTransition(idle, run, 0.2, &conditions);
    try world.bindAnimatorGraph(animator_id, &graph);

    update(&world, 0.1);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, clip_a), world.getEntityConst(animator_id).?.animator.?.default_clip_handle);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, clip_b), world.getEntityConst(animator_id).?.animator.?.next_clip_handle);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), world.getEntityConst(target_id).?.local_transform.translation[0], 0.0001);

    update(&world, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), world.getEntityConst(target_id).?.local_transform.translation[0], 0.0001);

    update(&world, 0.11);
    const animator = world.getEntityConst(animator_id).?.animator.?;
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, clip_b), animator.default_clip_handle);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, null), animator.next_clip_handle);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), world.getEntityConst(target_id).?.local_transform.translation[0], 0.0001);
}

test "animator graph parameters drive transitions through animator update" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{ .name = "GraphParamTarget" });
    const clip_a = try world.resources.createAnimationClip(.{
        .name = "Idle",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } },
            },
        },
    });
    const clip_b = try world.resources.createAnimationClip(.{
        .name = "Move",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 8.0, 0.0, 0.0 }, .{ 8.0, 0.0, 0.0 } },
            },
        },
    });
    const animator_id = try world.createEntity(.{
        .name = "GraphParamAnimator",
        .animator = .{},
    });
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    var graph = try animation_graph_mod.AnimationGraph.init(std.testing.allocator, "GraphParamAnimator");
    defer graph.deinit();
    const idle = try graph.addState("Idle", clip_a);
    const run = try graph.addState("Run", clip_b);
    graph.default_state = idle;
    try graph.addParameter("Speed", .float, .{ .float = 0.0 });
    const conditions = [_]animation_graph_mod.TransitionCondition{
        .{
            .parameter = .{
                .name = try std.testing.allocator.dupe(u8, "Speed"),
                .value = 0.5,
                .comparison = .greater,
            },
        },
    };
    defer std.testing.allocator.free(conditions[0].parameter.name);
    try graph.addTransition(idle, run, 0.2, &conditions);
    try world.bindAnimatorGraph(animator_id, &graph);
    try world.setAnimatorGraphParameterByName(animator_id, "Speed", .{ .float = 1.0 });

    update(&world, 0.01);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, clip_b), world.getEntityConst(animator_id).?.animator.?.next_clip_handle);

    update(&world, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), world.getEntityConst(target_id).?.local_transform.translation[0], 0.0001);
}
