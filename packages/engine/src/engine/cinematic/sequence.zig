const std = @import("std");
const track_mod = @import("track.zig");

pub const Track = track_mod.Track;
pub const TrackKind = track_mod.TrackKind;
pub const CameraPathTrack = track_mod.CameraPathTrack;
pub const AnimationTrack = track_mod.AnimationTrack;
pub const AudioTrack = track_mod.AudioTrack;
pub const EventTrack = track_mod.EventTrack;
pub const PropertyTrack = track_mod.PropertyTrack;
pub const EasingMode = track_mod.EasingMode;

// ---------------------------------------------------------------------------
// Sequence — the top-level cinematic asset
// ---------------------------------------------------------------------------

pub const current_sequence_version: u32 = 1;

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "",
    fps: f32 = 30.0,
    duration: f32 = 0.0,
    tracks: std.ArrayListUnmanaged(Track) = .empty,

    pub fn init(allocator: std.mem.Allocator) Sequence {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Sequence) void {
        for (self.tracks.items) |*t| t.deinit(self.allocator);
        self.tracks.deinit(self.allocator);
        if (self.name.len > 0) self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn addTrack(self: *Sequence, t: Track) !void {
        try self.tracks.append(self.allocator, t);
    }

    pub fn removeTrack(self: *Sequence, index: usize) void {
        var removed = self.tracks.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    /// Recompute duration from the latest keyframe / event / clip end across all tracks.
    pub fn recomputeDuration(self: *Sequence) void {
        var max_time: f32 = 0.0;
        for (self.tracks.items) |t| {
            const end = switch (t) {
                .camera_path => |cp| blk: {
                    if (cp.keyframes.items.len == 0) break :blk @as(f32, 0.0);
                    break :blk cp.keyframes.items[cp.keyframes.items.len - 1].time;
                },
                .animation => |a| a.end_time,
                .audio => |a| a.end_time,
                .event => |ev| blk: {
                    if (ev.events.items.len == 0) break :blk @as(f32, 0.0);
                    break :blk ev.events.items[ev.events.items.len - 1].time;
                },
                .property => |p| blk: {
                    if (p.keyframes.items.len == 0) break :blk @as(f32, 0.0);
                    break :blk p.keyframes.items[p.keyframes.items.len - 1].time;
                },
            };
            if (end > max_time) max_time = end;
        }
        self.duration = max_time;
    }
};

// ---------------------------------------------------------------------------
// JSON serialization / deserialization for .guava_sequence files
// ---------------------------------------------------------------------------

/// On-disk JSON representation.
pub const SequenceFile = struct {
    version: u32 = current_sequence_version,
    name: []const u8 = "",
    fps: f32 = 30.0,
    duration: f32 = 0.0,
    tracks: []const TrackJson = &.{},
};

pub const TrackJson = struct {
    type: []const u8 = "property",
    target: []const u8 = "",
    // Camera-path fields
    keyframes: ?[]const CameraKeyframeJson = null,
    // Animation fields
    clip: ?[]const u8 = null,
    start_time: ?f32 = null,
    end_time: ?f32 = null,
    blend_in: ?f32 = null,
    blend_out: ?f32 = null,
    speed: ?f32 = null,
    // Audio fields
    volume: ?f32 = null,
    fade_in: ?f32 = null,
    fade_out: ?f32 = null,
    // Event fields
    events: ?[]const EventJson = null,
    // Property fields
    property: ?[]const u8 = null,
    scalar_keyframes: ?[]const ScalarKeyframeJson = null,
};

pub const CameraKeyframeJson = struct {
    time: f32 = 0,
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    fov: f32 = 60,
    easing: []const u8 = "linear",
};

pub const EventJson = struct {
    time: f32 = 0,
    name: []const u8 = "",
};

pub const ScalarKeyframeJson = struct {
    time: f32 = 0,
    value: f32 = 0,
    easing: []const u8 = "linear",
};

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

pub fn loadFromJson(allocator: std.mem.Allocator, source: []const u8) !Sequence {
    const parsed = try std.json.parseFromSlice(SequenceFile, allocator, source, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return buildSequenceFromFile(allocator, parsed.value);
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Sequence {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(source);
    return loadFromJson(allocator, source);
}

fn buildSequenceFromFile(allocator: std.mem.Allocator, file: SequenceFile) !Sequence {
    var seq = Sequence.init(allocator);
    errdefer seq.deinit();

    if (file.name.len > 0) {
        seq.name = try allocator.dupe(u8, file.name);
    }
    seq.fps = file.fps;
    seq.duration = file.duration;

    for (file.tracks) |tj| {
        const track = try buildTrackFromJson(allocator, tj);
        try seq.tracks.append(allocator, track);
    }
    return seq;
}

fn parseEasing(name: []const u8) EasingMode {
    if (std.mem.eql(u8, name, "step")) return .step;
    if (std.mem.eql(u8, name, "ease_in")) return .ease_in;
    if (std.mem.eql(u8, name, "ease_out")) return .ease_out;
    if (std.mem.eql(u8, name, "ease_in_out")) return .ease_in_out;
    return .linear;
}

fn buildTrackFromJson(allocator: std.mem.Allocator, tj: TrackJson) !Track {
    const target = if (tj.target.len > 0) try allocator.dupe(u8, tj.target) else "";

    if (std.mem.eql(u8, tj.type, "camera_path")) {
        var cp = CameraPathTrack{ .target = target };
        errdefer cp.deinit(allocator);
        if (tj.keyframes) |kfs| {
            try cp.keyframes.ensureTotalCapacity(allocator, kfs.len);
            for (kfs) |kj| {
                cp.keyframes.appendAssumeCapacity(.{
                    .time = kj.time,
                    .position = kj.position,
                    .rotation = kj.rotation,
                    .fov = kj.fov,
                    .easing = parseEasing(kj.easing),
                });
            }
        }
        return .{ .camera_path = cp };
    }

    if (std.mem.eql(u8, tj.type, "animation")) {
        return .{ .animation = .{
            .target = target,
            .clip_path = if (tj.clip) |c| try allocator.dupe(u8, c) else "",
            .start_time = tj.start_time orelse 0,
            .end_time = tj.end_time orelse 0,
            .blend_in = tj.blend_in orelse 0,
            .blend_out = tj.blend_out orelse 0,
            .speed = tj.speed orelse 1,
        } };
    }

    if (std.mem.eql(u8, tj.type, "audio")) {
        return .{ .audio = .{
            .target = target,
            .clip_path = if (tj.clip) |c| try allocator.dupe(u8, c) else "",
            .start_time = tj.start_time orelse 0,
            .end_time = tj.end_time orelse 0,
            .volume = tj.volume orelse 1,
            .fade_in = tj.fade_in orelse 0,
            .fade_out = tj.fade_out orelse 0,
        } };
    }

    if (std.mem.eql(u8, tj.type, "event")) {
        var et = EventTrack{ .target = target };
        errdefer et.deinit(allocator);
        if (tj.events) |evs| {
            try et.events.ensureTotalCapacity(allocator, evs.len);
            for (evs) |ej| {
                var entry = track_mod.EventEntry{ .time = ej.time };
                if (ej.name.len > 0) entry.name = try allocator.dupe(u8, ej.name);
                et.events.appendAssumeCapacity(entry);
            }
        }
        return .{ .event = et };
    }

    // Default: property track
    var pt = PropertyTrack{
        .target = target,
        .property = if (tj.property) |p| try allocator.dupe(u8, p) else "",
    };
    errdefer pt.deinit(allocator);
    if (tj.scalar_keyframes) |sks| {
        try pt.keyframes.ensureTotalCapacity(allocator, sks.len);
        for (sks) |sk| {
            pt.keyframes.appendAssumeCapacity(.{
                .time = sk.time,
                .value = sk.value,
                .easing = parseEasing(sk.easing),
            });
        }
    }
    return .{ .property = pt };
}

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

fn easingName(e: EasingMode) []const u8 {
    return switch (e) {
        .linear => "linear",
        .step => "step",
        .ease_in => "ease_in",
        .ease_out => "ease_out",
        .ease_in_out => "ease_in_out",
    };
}

/// Serialize the sequence to JSON-format bytes (caller owns the returned slice).
pub fn saveToJsonAlloc(seq: *const Sequence, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    var w = buf.writer(allocator);

    try w.writeAll("{\n");
    try w.print("  \"version\": {d},\n", .{current_sequence_version});
    try w.print("  \"name\": \"{s}\",\n", .{seq.name});
    try w.print("  \"fps\": {d},\n", .{seq.fps});
    try w.print("  \"duration\": {d},\n", .{seq.duration});
    try w.writeAll("  \"tracks\": [\n");

    for (seq.tracks.items, 0..) |t, ti| {
        try writeTrackJson(&w, allocator, t);
        if (ti + 1 < seq.tracks.items.len) try w.writeAll(",");
        try w.writeAll("\n");
    }

    try w.writeAll("  ]\n}\n");
    return buf.toOwnedSlice(allocator);
}

fn writeTrackJson(w: anytype, _: std.mem.Allocator, t: Track) !void {
    try w.writeAll("    { ");
    switch (t) {
        .camera_path => |cp| {
            try w.writeAll("\"type\": \"camera_path\", ");
            try w.print("\"target\": \"{s}\", ", .{cp.target});
            try w.writeAll("\"keyframes\": [");
            for (cp.keyframes.items, 0..) |kf, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{{ \"time\": {d}, \"position\": [{d}, {d}, {d}], \"rotation\": [{d}, {d}, {d}, {d}], \"fov\": {d}, \"easing\": \"{s}\" }}", .{
                    kf.time,
                    kf.position[0],
                    kf.position[1],
                    kf.position[2],
                    kf.rotation[0],
                    kf.rotation[1],
                    kf.rotation[2],
                    kf.rotation[3],
                    kf.fov,
                    easingName(kf.easing),
                });
            }
            try w.writeAll("]");
        },
        .animation => |a| {
            try w.print("\"type\": \"animation\", \"target\": \"{s}\", ", .{a.target});
            try w.print("\"clip\": \"{s}\", ", .{a.clip_path});
            try w.print("\"start_time\": {d}, \"end_time\": {d}, ", .{ a.start_time, a.end_time });
            try w.print("\"blend_in\": {d}, \"blend_out\": {d}, \"speed\": {d}", .{ a.blend_in, a.blend_out, a.speed });
        },
        .audio => |a| {
            try w.print("\"type\": \"audio\", \"target\": \"{s}\", ", .{a.target});
            try w.print("\"clip\": \"{s}\", ", .{a.clip_path});
            try w.print("\"start_time\": {d}, \"end_time\": {d}, ", .{ a.start_time, a.end_time });
            try w.print("\"volume\": {d}, \"fade_in\": {d}, \"fade_out\": {d}", .{ a.volume, a.fade_in, a.fade_out });
        },
        .event => |ev| {
            try w.print("\"type\": \"event\", \"target\": \"{s}\", ", .{ev.target});
            try w.writeAll("\"events\": [");
            for (ev.events.items, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{{ \"time\": {d}, \"name\": \"{s}\" }}", .{ e.time, e.name });
            }
            try w.writeAll("]");
        },
        .property => |p| {
            try w.print("\"type\": \"property\", \"target\": \"{s}\", ", .{p.target});
            try w.print("\"property\": \"{s}\", ", .{p.property});
            try w.writeAll("\"scalar_keyframes\": [");
            for (p.keyframes.items, 0..) |kf, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{{ \"time\": {d}, \"value\": {d}, \"easing\": \"{s}\" }}", .{ kf.time, kf.value, easingName(kf.easing) });
            }
            try w.writeAll("]");
        },
    }
    try w.writeAll(" }");
}

/// Write sequence JSON to a file path.
pub fn saveToPath(seq: *const Sequence, allocator: std.mem.Allocator, path: []const u8) !void {
    const data = try saveToJsonAlloc(seq, allocator);
    defer allocator.free(data);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "round-trip JSON" {
    const alloc = std.testing.allocator;

    var seq = Sequence.init(alloc);
    defer seq.deinit();

    seq.name = try alloc.dupe(u8, "TestSeq");
    seq.fps = 24.0;
    seq.duration = 5.0;

    // Add a property track
    var pt = PropertyTrack{ .target = try alloc.dupe(u8, "Sun"), .property = try alloc.dupe(u8, "intensity") };
    try pt.keyframes.append(alloc, .{ .time = 0.0, .value = 1.0 });
    try pt.keyframes.append(alloc, .{ .time = 5.0, .value = 0.3, .easing = .ease_out });
    try seq.addTrack(.{ .property = pt });

    const json = try saveToJsonAlloc(&seq, alloc);
    defer alloc.free(json);

    var loaded = try loadFromJson(alloc, json);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("TestSeq", loaded.name);
    try std.testing.expectApproxEqAbs(loaded.fps, 24.0, 0.01);
    try std.testing.expectEqual(@as(usize, 1), loaded.tracks.items.len);

    const loaded_pt = loaded.tracks.items[0].property;
    try std.testing.expectEqualStrings("Sun", loaded_pt.target);
    try std.testing.expectEqual(@as(usize, 2), loaded_pt.keyframes.items.len);
    try std.testing.expectApproxEqAbs(loaded_pt.keyframes.items[1].value, 0.3, 0.01);
}
