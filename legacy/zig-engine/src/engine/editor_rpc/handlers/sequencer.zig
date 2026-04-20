///! handlers/sequencer.zig — cinematic sequence editor RPC handler.
///!
///! Maintains a loaded sequence in process-lifetime static storage.
///! The Electron panel reads full state via getState and mutates via
///! individual CRUD calls (addTrack, removeTrack, addKeyframe, etc.).
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const cinematic = @import("../../cinematic/mod.zig");

const Sequence = cinematic.Sequence;
const Track = cinematic.Track;
const TrackKind = cinematic.TrackKind;
const EasingMode = cinematic.keyframe.EasingMode;
const CameraKeyframe = cinematic.track.CameraKeyframe;
const EventEntry = cinematic.track.EventEntry;
const ScalarKeyframe = cinematic.keyframe.ScalarKeyframe;

// ── Static state (process-lifetime) ─────────────────────────────

const alloc = std.heap.page_allocator;

var current_sequence: ?Sequence = null;
var current_time: f32 = 0.0;
var is_playing: bool = false;
var playback_speed: f32 = 1.0;
var file_path_buffer: [256]u8 = [_]u8{0} ** 256;
var file_path_len: usize = 0;

// ── Helpers ─────────────────────────────────────────────────────

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn jsonFloat(v: std.json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

fn parseEasing(s: []const u8) EasingMode {
    if (strEql(s, "step")) return .step;
    if (strEql(s, "ease_in")) return .ease_in;
    if (strEql(s, "ease_out")) return .ease_out;
    if (strEql(s, "ease_in_out")) return .ease_in_out;
    return .linear;
}

fn getParamArray(ctx: *Ctx, key: []const u8) ?std.json.Array {
    const p = ctx.params orelse return null;
    const val = p.object.get(key) orelse return null;
    return switch (val) {
        .array => |a| a,
        else => null,
    };
}

fn writeJsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(a, c),
        }
    }
    try buf.append(a, '"');
}

fn writeFloat(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: f32) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:.4}", .{v}) catch "0";
    try buf.appendSlice(a, s);
}

fn writeInt(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: usize) !void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0";
    try buf.appendSlice(a, s);
}

// ═══════════════════════════════════════════════════════════════════
//  Public handlers
// ═══════════════════════════════════════════════════════════════════

/// sequencer.getState() → full snapshot for UI rendering.
pub fn getState(ctx: *Ctx) !void {
    const seq = current_sequence orelse {
        try ctx.reply(.{
            .loaded = false,
            .currentTime = current_time,
            .isPlaying = is_playing,
            .speed = playback_speed,
        });
        return;
    };

    const a = ctx.allocator;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "{\"loaded\":true,\"name\":");
    try writeJsonStr(&buf, a, seq.name);
    try buf.appendSlice(a, ",\"fps\":");
    try writeFloat(&buf, a, seq.fps);
    try buf.appendSlice(a, ",\"duration\":");
    try writeFloat(&buf, a, seq.duration);
    try buf.appendSlice(a, ",\"currentTime\":");
    try writeFloat(&buf, a, current_time);
    try buf.appendSlice(a, if (is_playing) ",\"isPlaying\":true" else ",\"isPlaying\":false");
    try buf.appendSlice(a, ",\"speed\":");
    try writeFloat(&buf, a, playback_speed);

    try buf.appendSlice(a, ",\"tracks\":[");
    for (seq.tracks.items, 0..) |track, i| {
        if (i > 0) try buf.append(a, ',');
        try writeTrackJson(&buf, a, track, i);
    }
    try buf.appendSlice(a, "]");

    if (file_path_len > 0) {
        try buf.appendSlice(a, ",\"filePath\":");
        try writeJsonStr(&buf, a, file_path_buffer[0..file_path_len]);
    }

    try buf.append(a, '}');
    ctx.replyRaw(try buf.toOwnedSlice(a));
}

fn writeTrackJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, track: Track, index: usize) !void {
    try buf.appendSlice(a, "{\"index\":");
    try writeInt(buf, a, index);
    try buf.appendSlice(a, ",\"kind\":");
    try writeJsonStr(buf, a, @tagName(track));
    try buf.appendSlice(a, ",\"target\":");
    try writeJsonStr(buf, a, track.name());

    switch (track) {
        .camera_path => |cp| {
            try buf.appendSlice(a, ",\"keyframes\":[");
            for (cp.keyframes.items, 0..) |kf, ki| {
                if (ki > 0) try buf.append(a, ',');
                try buf.appendSlice(a, "{\"index\":");
                try writeInt(buf, a, ki);
                try buf.appendSlice(a, ",\"time\":");
                try writeFloat(buf, a, kf.time);
                try buf.appendSlice(a, ",\"position\":[");
                try writeFloat(buf, a, kf.position[0]);
                try buf.append(a, ',');
                try writeFloat(buf, a, kf.position[1]);
                try buf.append(a, ',');
                try writeFloat(buf, a, kf.position[2]);
                try buf.appendSlice(a, "],\"rotation\":[");
                try writeFloat(buf, a, kf.rotation[0]);
                try buf.append(a, ',');
                try writeFloat(buf, a, kf.rotation[1]);
                try buf.append(a, ',');
                try writeFloat(buf, a, kf.rotation[2]);
                try buf.append(a, ',');
                try writeFloat(buf, a, kf.rotation[3]);
                try buf.appendSlice(a, "],\"fov\":");
                try writeFloat(buf, a, kf.fov);
                try buf.appendSlice(a, ",\"easing\":");
                try writeJsonStr(buf, a, @tagName(kf.easing));
                try buf.append(a, '}');
            }
            try buf.appendSlice(a, "]");
        },
        .animation => |an| {
            try buf.appendSlice(a, ",\"clipPath\":");
            try writeJsonStr(buf, a, an.clip_path);
            try buf.appendSlice(a, ",\"startTime\":");
            try writeFloat(buf, a, an.start_time);
            try buf.appendSlice(a, ",\"endTime\":");
            try writeFloat(buf, a, an.end_time);
            try buf.appendSlice(a, ",\"blendIn\":");
            try writeFloat(buf, a, an.blend_in);
            try buf.appendSlice(a, ",\"blendOut\":");
            try writeFloat(buf, a, an.blend_out);
            try buf.appendSlice(a, ",\"speed\":");
            try writeFloat(buf, a, an.speed);
        },
        .audio => |au| {
            try buf.appendSlice(a, ",\"clipPath\":");
            try writeJsonStr(buf, a, au.clip_path);
            try buf.appendSlice(a, ",\"startTime\":");
            try writeFloat(buf, a, au.start_time);
            try buf.appendSlice(a, ",\"endTime\":");
            try writeFloat(buf, a, au.end_time);
            try buf.appendSlice(a, ",\"volume\":");
            try writeFloat(buf, a, au.volume);
            try buf.appendSlice(a, ",\"fadeIn\":");
            try writeFloat(buf, a, au.fade_in);
            try buf.appendSlice(a, ",\"fadeOut\":");
            try writeFloat(buf, a, au.fade_out);
        },
        .event => |ev| {
            try buf.appendSlice(a, ",\"events\":[");
            for (ev.events.items, 0..) |entry, ei| {
                if (ei > 0) try buf.append(a, ',');
                try buf.appendSlice(a, "{\"index\":");
                try writeInt(buf, a, ei);
                try buf.appendSlice(a, ",\"time\":");
                try writeFloat(buf, a, entry.time);
                try buf.appendSlice(a, ",\"name\":");
                try writeJsonStr(buf, a, entry.name);
                try buf.append(a, '}');
            }
            try buf.appendSlice(a, "]");
        },
        .property => |p| {
            try buf.appendSlice(a, ",\"property\":");
            try writeJsonStr(buf, a, p.property);
            try buf.appendSlice(a, ",\"keyframes\":[");
            for (p.keyframes.items, 0..) |kf, ki| {
                if (ki > 0) try buf.append(a, ',');
                try buf.appendSlice(a, "{\"index\":");
                try writeInt(buf, a, ki);
                try buf.appendSlice(a, ",\"time\":");
                try writeFloat(buf, a, kf.time);
                try buf.appendSlice(a, ",\"value\":");
                try writeFloat(buf, a, kf.value);
                try buf.appendSlice(a, ",\"easing\":");
                try writeJsonStr(buf, a, @tagName(kf.easing));
                try buf.append(a, '}');
            }
            try buf.appendSlice(a, "]");
        },
    }
    try buf.append(a, '}');
}

/// sequencer.create(name?, fps?) → create a new empty sequence.
pub fn create(ctx: *Ctx) !void {
    if (current_sequence) |*old| old.deinit();
    current_sequence = Sequence.init(alloc);
    current_time = 0;
    is_playing = false;
    file_path_len = 0;

    if (try ctx.paramOpt([]const u8, "name")) |name| {
        if (name.len > 0)
            current_sequence.?.name = try alloc.dupe(u8, name);
    }
    if (try ctx.paramOpt(f64, "fps")) |fps| {
        current_sequence.?.fps = @floatCast(fps);
    }
    try ctx.reply(.{ .ok = true });
}

/// sequencer.load(path) → load a .guava_sequence file.
pub fn load(ctx: *Ctx) !void {
    const path = try ctx.param([]const u8, "path");
    const loaded = cinematic.loadFromPath(alloc, path) catch {
        try ctx.reply(.{ .ok = false, .@"error" = "Failed to load sequence" });
        return;
    };
    if (current_sequence) |*old| old.deinit();
    current_sequence = loaded;
    current_time = 0;
    is_playing = false;

    const plen = @min(path.len, file_path_buffer.len);
    @memcpy(file_path_buffer[0..plen], path[0..plen]);
    file_path_len = plen;

    try ctx.reply(.{ .ok = true });
}

/// sequencer.save(path?) → save current sequence.
pub fn save(ctx: *Ctx) !void {
    var seq = current_sequence orelse {
        try ctx.reply(.{ .ok = false, .@"error" = "No sequence loaded" });
        return;
    };

    const path = (try ctx.paramOpt([]const u8, "path")) orelse blk: {
        if (file_path_len > 0) break :blk file_path_buffer[0..file_path_len];
        try ctx.reply(.{ .ok = false, .@"error" = "No file path specified" });
        return;
    };

    cinematic.saveToPath(&seq, alloc, path) catch {
        try ctx.reply(.{ .ok = false, .@"error" = "Failed to save sequence" });
        return;
    };

    const plen = @min(path.len, file_path_buffer.len);
    @memcpy(file_path_buffer[0..plen], path[0..plen]);
    file_path_len = plen;

    try ctx.reply(.{ .ok = true });
}

/// sequencer.setProperties(name?, fps?, duration?) → update sequence metadata.
pub fn setProperties(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);

    if (try ctx.paramOpt([]const u8, "name")) |name| {
        if (seq.name.len > 0) alloc.free(seq.name);
        seq.name = if (name.len > 0) try alloc.dupe(u8, name) else "";
    }
    if (try ctx.paramOpt(f64, "fps")) |fps| seq.fps = @floatCast(fps);
    if (try ctx.paramOpt(f64, "duration")) |d| seq.duration = @floatCast(d);

    try ctx.reply(.{});
}

/// sequencer.addTrack(kind, target) → add a new track.
pub fn addTrack(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);
    const kind_str = try ctx.param([]const u8, "kind");
    const target_str = try ctx.param([]const u8, "target");
    const target = try alloc.dupe(u8, target_str);

    const track: Track = if (strEql(kind_str, "camera_path"))
        .{ .camera_path = .{ .target = target } }
    else if (strEql(kind_str, "animation"))
        .{ .animation = .{ .target = target } }
    else if (strEql(kind_str, "audio"))
        .{ .audio = .{ .target = target } }
    else if (strEql(kind_str, "event"))
        .{ .event = .{ .target = target } }
    else if (strEql(kind_str, "property"))
        .{ .property = .{ .target = target } }
    else {
        alloc.free(target);
        return error.InvalidArguments;
    };

    try seq.addTrack(track);
    try ctx.reply(.{ .index = seq.tracks.items.len - 1 });
}

/// sequencer.removeTrack(index) → remove a track by index.
pub fn removeTrack(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);
    const index: usize = @intCast(try ctx.param(u64, "index"));
    if (index >= seq.tracks.items.len) return error.InvalidArguments;
    seq.removeTrack(index);
    try ctx.reply(.{});
}

/// sequencer.updateTrack(index, ...properties) → update track-level properties.
pub fn updateTrack(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);
    const index: usize = @intCast(try ctx.param(u64, "index"));
    if (index >= seq.tracks.items.len) return error.InvalidArguments;

    switch (seq.tracks.items[index]) {
        .animation => |*a| {
            if (try ctx.paramOpt(f64, "startTime")) |v| a.start_time = @floatCast(v);
            if (try ctx.paramOpt(f64, "endTime")) |v| a.end_time = @floatCast(v);
            if (try ctx.paramOpt(f64, "blendIn")) |v| a.blend_in = @floatCast(v);
            if (try ctx.paramOpt(f64, "blendOut")) |v| a.blend_out = @floatCast(v);
            if (try ctx.paramOpt(f64, "speed")) |v| a.speed = @floatCast(v);
            if (try ctx.paramOpt([]const u8, "clipPath")) |v| {
                if (a.clip_path.len > 0) alloc.free(a.clip_path);
                a.clip_path = if (v.len > 0) try alloc.dupe(u8, v) else "";
            }
        },
        .audio => |*a| {
            if (try ctx.paramOpt(f64, "startTime")) |v| a.start_time = @floatCast(v);
            if (try ctx.paramOpt(f64, "endTime")) |v| a.end_time = @floatCast(v);
            if (try ctx.paramOpt(f64, "volume")) |v| a.volume = @floatCast(v);
            if (try ctx.paramOpt(f64, "fadeIn")) |v| a.fade_in = @floatCast(v);
            if (try ctx.paramOpt(f64, "fadeOut")) |v| a.fade_out = @floatCast(v);
            if (try ctx.paramOpt([]const u8, "clipPath")) |v| {
                if (a.clip_path.len > 0) alloc.free(a.clip_path);
                a.clip_path = if (v.len > 0) try alloc.dupe(u8, v) else "";
            }
        },
        .property => |*p| {
            if (try ctx.paramOpt([]const u8, "property")) |v| {
                if (p.property.len > 0) alloc.free(p.property);
                p.property = if (v.len > 0) try alloc.dupe(u8, v) else "";
            }
        },
        .camera_path, .event => {},
    }
    try ctx.reply(.{});
}

/// sequencer.addKeyframe(trackIndex, time, ...data) → add a keyframe.
pub fn addKeyframe(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);
    const ti: usize = @intCast(try ctx.param(u64, "trackIndex"));
    if (ti >= seq.tracks.items.len) return error.InvalidArguments;
    const time: f32 = @floatCast(try ctx.param(f64, "time"));

    switch (seq.tracks.items[ti]) {
        .camera_path => |*cp| {
            var kf = CameraKeyframe{ .time = time };
            if (getParamArray(ctx, "position")) |arr| {
                if (arr.items.len >= 3)
                    kf.position = .{ jsonFloat(arr.items[0]), jsonFloat(arr.items[1]), jsonFloat(arr.items[2]) };
            }
            if (getParamArray(ctx, "rotation")) |arr| {
                if (arr.items.len >= 4)
                    kf.rotation = .{ jsonFloat(arr.items[0]), jsonFloat(arr.items[1]), jsonFloat(arr.items[2]), jsonFloat(arr.items[3]) };
            }
            if (try ctx.paramOpt(f64, "fov")) |v| kf.fov = @floatCast(v);
            if (try ctx.paramOpt([]const u8, "easing")) |e| kf.easing = parseEasing(e);
            try cp.keyframes.append(alloc, kf);
            std.mem.sort(CameraKeyframe, cp.keyframes.items, {}, struct {
                fn lt(_: void, a: CameraKeyframe, b: CameraKeyframe) bool {
                    return a.time < b.time;
                }
            }.lt);
            try ctx.reply(.{ .count = cp.keyframes.items.len });
        },
        .event => |*ev| {
            const name_str = (try ctx.paramOpt([]const u8, "name")) orelse "";
            var entry = EventEntry{ .time = time };
            if (name_str.len > 0) entry.name = try alloc.dupe(u8, name_str);
            try ev.events.append(alloc, entry);
            std.mem.sort(EventEntry, ev.events.items, {}, struct {
                fn lt(_: void, a: EventEntry, b: EventEntry) bool {
                    return a.time < b.time;
                }
            }.lt);
            try ctx.reply(.{ .count = ev.events.items.len });
        },
        .property => |*p| {
            const value: f32 = @floatCast((try ctx.paramOpt(f64, "value")) orelse 0.0);
            const easing_str = (try ctx.paramOpt([]const u8, "easing")) orelse "linear";
            try p.keyframes.append(alloc, .{ .time = time, .value = value, .easing = parseEasing(easing_str) });
            std.mem.sort(ScalarKeyframe, p.keyframes.items, {}, struct {
                fn lt(_: void, a: ScalarKeyframe, b: ScalarKeyframe) bool {
                    return a.time < b.time;
                }
            }.lt);
            try ctx.reply(.{ .count = p.keyframes.items.len });
        },
        .animation, .audio => {
            try ctx.reply(.{ .@"error" = "Track type does not support keyframes" });
        },
    }
}

/// sequencer.removeKeyframe(trackIndex, keyframeIndex)
pub fn removeKeyframe(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);
    const ti: usize = @intCast(try ctx.param(u64, "trackIndex"));
    const ki: usize = @intCast(try ctx.param(u64, "keyframeIndex"));
    if (ti >= seq.tracks.items.len) return error.InvalidArguments;

    switch (seq.tracks.items[ti]) {
        .camera_path => |*cp| {
            if (ki >= cp.keyframes.items.len) return error.InvalidArguments;
            _ = cp.keyframes.orderedRemove(ki);
        },
        .event => |*ev| {
            if (ki >= ev.events.items.len) return error.InvalidArguments;
            _ = ev.events.orderedRemove(ki);
        },
        .property => |*p| {
            if (ki >= p.keyframes.items.len) return error.InvalidArguments;
            _ = p.keyframes.orderedRemove(ki);
        },
        .animation, .audio => {
            try ctx.reply(.{ .@"error" = "Track type does not support keyframes" });
            return;
        },
    }
    try ctx.reply(.{});
}

/// sequencer.updateKeyframe(trackIndex, keyframeIndex, ...data)
pub fn updateKeyframe(ctx: *Ctx) !void {
    const seq = &(current_sequence orelse return error.InvalidArguments);
    const ti: usize = @intCast(try ctx.param(u64, "trackIndex"));
    const ki: usize = @intCast(try ctx.param(u64, "keyframeIndex"));
    if (ti >= seq.tracks.items.len) return error.InvalidArguments;

    switch (seq.tracks.items[ti]) {
        .camera_path => |*cp| {
            if (ki >= cp.keyframes.items.len) return error.InvalidArguments;
            const kf = &cp.keyframes.items[ki];
            if (try ctx.paramOpt(f64, "time")) |v| kf.time = @floatCast(v);
            if (getParamArray(ctx, "position")) |arr| {
                if (arr.items.len >= 3) kf.position = .{ jsonFloat(arr.items[0]), jsonFloat(arr.items[1]), jsonFloat(arr.items[2]) };
            }
            if (getParamArray(ctx, "rotation")) |arr| {
                if (arr.items.len >= 4) kf.rotation = .{ jsonFloat(arr.items[0]), jsonFloat(arr.items[1]), jsonFloat(arr.items[2]), jsonFloat(arr.items[3]) };
            }
            if (try ctx.paramOpt(f64, "fov")) |v| kf.fov = @floatCast(v);
            if (try ctx.paramOpt([]const u8, "easing")) |e| kf.easing = parseEasing(e);
        },
        .event => |*ev| {
            if (ki >= ev.events.items.len) return error.InvalidArguments;
            const entry = &ev.events.items[ki];
            if (try ctx.paramOpt(f64, "time")) |v| entry.time = @floatCast(v);
            if (try ctx.paramOpt([]const u8, "name")) |n| {
                if (entry.name.len > 0) alloc.free(entry.name);
                entry.name = if (n.len > 0) try alloc.dupe(u8, n) else "";
            }
        },
        .property => |*p| {
            if (ki >= p.keyframes.items.len) return error.InvalidArguments;
            const kf = &p.keyframes.items[ki];
            if (try ctx.paramOpt(f64, "time")) |v| kf.time = @floatCast(v);
            if (try ctx.paramOpt(f64, "value")) |v| kf.value = @floatCast(v);
            if (try ctx.paramOpt([]const u8, "easing")) |e| kf.easing = parseEasing(e);
        },
        .animation, .audio => {},
    }
    try ctx.reply(.{});
}

/// sequencer.play()
pub fn play(ctx: *Ctx) !void {
    is_playing = true;
    try ctx.reply(.{});
}

/// sequencer.pause()
pub fn pause(ctx: *Ctx) !void {
    is_playing = false;
    try ctx.reply(.{});
}

/// sequencer.stop()
pub fn stop(ctx: *Ctx) !void {
    is_playing = false;
    current_time = 0;
    try ctx.reply(.{});
}

/// sequencer.seek(time)
pub fn seek(ctx: *Ctx) !void {
    const time: f32 = @floatCast(try ctx.param(f64, "time"));
    current_time = time;
    try ctx.reply(.{});
}

/// sequencer.setSpeed(speed)
pub fn setSpeed(ctx: *Ctx) !void {
    playback_speed = @floatCast(try ctx.param(f64, "speed"));
    try ctx.reply(.{});
}

/// sequencer.recomputeDuration()
pub fn recomputeDuration(ctx: *Ctx) !void {
    if (current_sequence) |*seq| {
        seq.recomputeDuration();
        try ctx.reply(.{ .duration = seq.duration });
    } else {
        try ctx.reply(.{ .duration = @as(f32, 0.0) });
    }
}
