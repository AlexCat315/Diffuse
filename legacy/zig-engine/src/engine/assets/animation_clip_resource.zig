const std = @import("std");

pub const Interpolation = enum {
    step,
    linear,
    cubic_spline,

    pub fn fromGltf(name: []const u8) Interpolation {
        if (std.mem.eql(u8, name, "STEP")) return .step;
        if (std.mem.eql(u8, name, "CUBICSPLINE")) return .cubic_spline;
        return .linear;
    }
};

pub const Vec3Track = struct {
    target_entity_index: u32,
    interpolation: Interpolation = .linear,
    times: []f32,
    values: [][3]f32,

    fn deinit(self: *Vec3Track, allocator: std.mem.Allocator) void {
        allocator.free(self.times);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const QuatTrack = struct {
    target_entity_index: u32,
    interpolation: Interpolation = .linear,
    times: []f32,
    values: [][4]f32,

    fn deinit(self: *QuatTrack, allocator: std.mem.Allocator) void {
        allocator.free(self.times);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const Vec3TrackDesc = struct {
    target_entity_index: u32,
    interpolation: Interpolation = .linear,
    times: []const f32,
    values: []const [3]f32,
};

pub const QuatTrackDesc = struct {
    target_entity_index: u32,
    interpolation: Interpolation = .linear,
    times: []const f32,
    values: []const [4]f32,
};

pub const AnimationClipResource = struct {
    name: []u8,
    duration: f32,
    translation_tracks: []Vec3Track,
    rotation_tracks: []QuatTrack,
    scale_tracks: []Vec3Track,

    pub fn deinit(self: *AnimationClipResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.translation_tracks) |*track| {
            track.deinit(allocator);
        }
        allocator.free(self.translation_tracks);
        for (self.rotation_tracks) |*track| {
            track.deinit(allocator);
        }
        allocator.free(self.rotation_tracks);
        for (self.scale_tracks) |*track| {
            track.deinit(allocator);
        }
        allocator.free(self.scale_tracks);
        self.* = undefined;
    }
};

pub const AnimationClipResourceDesc = struct {
    name: []const u8,
    duration: f32,
    translation_tracks: []const Vec3TrackDesc = &.{},
    rotation_tracks: []const QuatTrackDesc = &.{},
    scale_tracks: []const Vec3TrackDesc = &.{},
};

pub fn clone(allocator: std.mem.Allocator, desc: AnimationClipResourceDesc) !AnimationClipResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .duration = desc.duration,
        .translation_tracks = try cloneVec3Tracks(allocator, desc.translation_tracks),
        .rotation_tracks = try cloneQuatTracks(allocator, desc.rotation_tracks),
        .scale_tracks = try cloneVec3Tracks(allocator, desc.scale_tracks),
    };
}

fn cloneVec3Tracks(allocator: std.mem.Allocator, tracks: []const Vec3TrackDesc) ![]Vec3Track {
    const owned = try allocator.alloc(Vec3Track, tracks.len);
    errdefer allocator.free(owned);

    var index: usize = 0;
    errdefer {
        while (index > 0) {
            index -= 1;
            owned[index].deinit(allocator);
        }
    }

    for (tracks, 0..) |track, track_index| {
        owned[track_index] = .{
            .target_entity_index = track.target_entity_index,
            .interpolation = track.interpolation,
            .times = try allocator.dupe(f32, track.times),
            .values = try allocator.dupe([3]f32, track.values),
        };
        index = track_index + 1;
    }
    return owned;
}

fn cloneQuatTracks(allocator: std.mem.Allocator, tracks: []const QuatTrackDesc) ![]QuatTrack {
    const owned = try allocator.alloc(QuatTrack, tracks.len);
    errdefer allocator.free(owned);

    var index: usize = 0;
    errdefer {
        while (index > 0) {
            index -= 1;
            owned[index].deinit(allocator);
        }
    }

    for (tracks, 0..) |track, track_index| {
        owned[track_index] = .{
            .target_entity_index = track.target_entity_index,
            .interpolation = track.interpolation,
            .times = try allocator.dupe(f32, track.times),
            .values = try allocator.dupe([4]f32, track.values),
        };
        index = track_index + 1;
    }
    return owned;
}

test "animation clip resource clone stores keyed tracks" {
    const translation_times = [_]f32{ 0.0, 1.0 };
    const translation_values = [_][3]f32{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
    };
    const rotation_times = [_]f32{ 0.0, 1.0 };
    const rotation_values = [_][4]f32{
        .{ 0.0, 0.0, 0.0, 1.0 },
        .{ 0.0, 0.70710677, 0.0, 0.70710677 },
    };

    var resource = try clone(std.testing.allocator, .{
        .name = "Walk",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 1,
                .times = translation_times[0..],
                .values = translation_values[0..],
            },
        },
        .rotation_tracks = &.{
            .{
                .target_entity_index = 2,
                .times = rotation_times[0..],
                .values = rotation_values[0..],
            },
        },
    });
    defer resource.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), resource.translation_tracks.len);
    try std.testing.expectEqual(@as(usize, 1), resource.rotation_tracks.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), resource.duration, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), resource.translation_tracks[0].target_entity_index);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710677), resource.rotation_tracks[0].values[1][1], 0.0001);
}
