const std = @import("std");
const keyframe = @import("keyframe.zig");

pub const ScalarKeyframe = keyframe.ScalarKeyframe;
pub const Vec3Keyframe = keyframe.Vec3Keyframe;
pub const QuatKeyframe = keyframe.QuatKeyframe;
pub const EasingMode = keyframe.EasingMode;

// ---------------------------------------------------------------------------
// Track kinds
// ---------------------------------------------------------------------------

/// Discriminant for track types stored in a Sequence.
pub const TrackKind = enum {
    camera_path,
    animation,
    audio,
    event,
    property,
};

/// A single track in a Sequence timeline.
pub const Track = union(TrackKind) {
    camera_path: CameraPathTrack,
    animation: AnimationTrack,
    audio: AudioTrack,
    event: EventTrack,
    property: PropertyTrack,

    pub fn name(self: Track) []const u8 {
        return switch (self) {
            .camera_path => |t| t.target,
            .animation => |t| t.target,
            .audio => |t| t.target,
            .event => |t| t.target,
            .property => |t| t.target,
        };
    }

    pub fn deinit(self: *Track, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .camera_path => |*t| t.deinit(allocator),
            .animation => |*t| t.deinit(allocator),
            .audio => |*t| t.deinit(allocator),
            .event => |*t| t.deinit(allocator),
            .property => |*t| t.deinit(allocator),
        }
    }
};

// ---------------------------------------------------------------------------
// Camera Path Track
// ---------------------------------------------------------------------------

pub const CameraKeyframe = struct {
    time: f32,
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 }, // quaternion xyzw
    fov: f32 = 60.0,
    easing: EasingMode = .linear,
};

pub const CameraPathTrack = struct {
    target: []const u8, // entity name
    keyframes: std.ArrayListUnmanaged(CameraKeyframe) = .empty,

    pub fn deinit(self: *CameraPathTrack, allocator: std.mem.Allocator) void {
        self.keyframes.deinit(allocator);
        if (self.target.len > 0) allocator.free(self.target);
    }

    /// Evaluate position, rotation, and fov at a given time.
    pub fn evaluate(self: *const CameraPathTrack, time: f32) struct { position: [3]f32, rotation: [4]f32, fov: f32 } {
        const items = self.keyframes.items;
        if (items.len == 0) return .{ .position = .{ 0, 0, 0 }, .rotation = .{ 0, 0, 0, 1 }, .fov = 60.0 };
        if (items.len == 1 or time <= items[0].time) {
            return .{ .position = items[0].position, .rotation = items[0].rotation, .fov = items[0].fov };
        }
        if (time >= items[items.len - 1].time) {
            const last = items[items.len - 1];
            return .{ .position = last.position, .rotation = last.rotation, .fov = last.fov };
        }

        // Binary search for the surrounding pair.
        var lo: usize = 0;
        var hi: usize = items.len - 1;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].time <= time) lo = mid else hi = mid;
        }

        const a = items[lo];
        const b = items[hi];
        const span = b.time - a.time;
        const raw_t = if (span > 0.00001) (time - a.time) / span else 0.0;
        const t = a.easing.evaluate(raw_t);

        return .{
            .position = keyframe.lerpVec3(a.position, b.position, t),
            .rotation = keyframe.slerpQuat(a.rotation, b.rotation, t),
            .fov = keyframe.lerpScalar(a.fov, b.fov, t),
        };
    }
};

// ---------------------------------------------------------------------------
// Animation Track — references an animation clip to play on an entity
// ---------------------------------------------------------------------------

pub const AnimationTrack = struct {
    target: []const u8,
    clip_path: []const u8 = "", // asset path to clip
    start_time: f32 = 0.0,
    end_time: f32 = 0.0,
    blend_in: f32 = 0.0,
    blend_out: f32 = 0.0,
    speed: f32 = 1.0,

    pub fn deinit(self: *AnimationTrack, allocator: std.mem.Allocator) void {
        if (self.target.len > 0) allocator.free(self.target);
        if (self.clip_path.len > 0) allocator.free(self.clip_path);
    }
};

// ---------------------------------------------------------------------------
// Audio Track — plays an audio clip at a time range
// ---------------------------------------------------------------------------

pub const AudioTrack = struct {
    target: []const u8,
    clip_path: []const u8 = "",
    start_time: f32 = 0.0,
    end_time: f32 = 0.0,
    volume: f32 = 1.0,
    fade_in: f32 = 0.0,
    fade_out: f32 = 0.0,

    pub fn deinit(self: *AudioTrack, allocator: std.mem.Allocator) void {
        if (self.target.len > 0) allocator.free(self.target);
        if (self.clip_path.len > 0) allocator.free(self.clip_path);
    }
};

// ---------------------------------------------------------------------------
// Event Track — fires named events at specific times
// ---------------------------------------------------------------------------

pub const EventEntry = struct {
    time: f32,
    name: []const u8 = "",

    pub fn deinit(self: *EventEntry, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
    }
};

pub const EventTrack = struct {
    target: []const u8,
    events: std.ArrayListUnmanaged(EventEntry) = .empty,

    pub fn deinit(self: *EventTrack, allocator: std.mem.Allocator) void {
        for (self.events.items) |*e| e.deinit(allocator);
        self.events.deinit(allocator);
        if (self.target.len > 0) allocator.free(self.target);
    }
};

// ---------------------------------------------------------------------------
// Property Track — animates a named property with scalar keyframes
// ---------------------------------------------------------------------------

pub const PropertyTrack = struct {
    target: []const u8,
    property: []const u8 = "",
    keyframes: std.ArrayListUnmanaged(ScalarKeyframe) = .empty,

    pub fn deinit(self: *PropertyTrack, allocator: std.mem.Allocator) void {
        self.keyframes.deinit(allocator);
        if (self.target.len > 0) allocator.free(self.target);
        if (self.property.len > 0) allocator.free(self.property);
    }

    pub fn evaluate(self: *const PropertyTrack, time: f32) f32 {
        return keyframe.evaluateScalar(self.keyframes.items, time);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "CameraPathTrack evaluate single keyframe" {
    var track = CameraPathTrack{
        .target = "",
    };
    defer track.keyframes.deinit(std.testing.allocator);

    try track.keyframes.append(std.testing.allocator, .{
        .time = 0.0,
        .position = .{ 1, 2, 3 },
        .rotation = .{ 0, 0, 0, 1 },
        .fov = 45.0,
    });

    const result = track.evaluate(0.0);
    try std.testing.expectApproxEqAbs(result.position[0], 1.0, 0.01);
    try std.testing.expectApproxEqAbs(result.fov, 45.0, 0.01);
}

test "CameraPathTrack evaluate between two keyframes" {
    var track = CameraPathTrack{
        .target = "",
    };
    defer track.keyframes.deinit(std.testing.allocator);

    try track.keyframes.append(std.testing.allocator, .{
        .time = 0.0,
        .position = .{ 0, 0, 0 },
        .fov = 40.0,
    });
    try track.keyframes.append(std.testing.allocator, .{
        .time = 2.0,
        .position = .{ 10, 0, 0 },
        .fov = 60.0,
    });

    const result = track.evaluate(1.0);
    try std.testing.expectApproxEqAbs(result.position[0], 5.0, 0.01);
    try std.testing.expectApproxEqAbs(result.fov, 50.0, 0.01);
}
