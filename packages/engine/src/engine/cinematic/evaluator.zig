const std = @import("std");
const sequence_mod = @import("sequence.zig");
const track_mod = @import("track.zig");
const keyframe_mod = @import("keyframe.zig");

pub const Sequence = sequence_mod.Sequence;
pub const Track = track_mod.Track;

// ---------------------------------------------------------------------------
// Playback state for a running Sequence.
// ---------------------------------------------------------------------------

pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
};

pub const SequencePlayback = struct {
    sequence: *const Sequence,
    current_time: f32 = 0.0,
    state: PlaybackState = .stopped,
    looping: bool = false,
    speed: f32 = 1.0,

    /// Fired events are tracked per-play so we don't re-fire on the same frame.
    last_event_time: f32 = -1.0,

    pub fn init(sequence: *const Sequence) SequencePlayback {
        return .{ .sequence = sequence };
    }

    pub fn play(self: *SequencePlayback) void {
        self.state = .playing;
    }

    pub fn pause(self: *SequencePlayback) void {
        if (self.state == .playing) self.state = .paused;
    }

    pub fn stop(self: *SequencePlayback) void {
        self.state = .stopped;
        self.current_time = 0.0;
        self.last_event_time = -1.0;
    }

    pub fn seekTo(self: *SequencePlayback, time: f32) void {
        self.current_time = std.math.clamp(time, 0.0, self.sequence.duration);
    }

    /// Advance the playback clock by `delta_seconds`.
    /// Returns `true` while the sequence is still active (playing or paused).
    pub fn advance(self: *SequencePlayback, delta_seconds: f32) bool {
        if (self.state != .playing) return self.state != .stopped;

        self.current_time += delta_seconds * self.speed;

        if (self.current_time >= self.sequence.duration) {
            if (self.looping) {
                self.current_time = @mod(self.current_time, self.sequence.duration);
                self.last_event_time = -1.0;
            } else {
                self.current_time = self.sequence.duration;
                self.state = .stopped;
                return false;
            }
        }
        return true;
    }

    /// Returns `true` when the playback has finished (reached end and not looping).
    pub fn isFinished(self: *const SequencePlayback) bool {
        return self.state == .stopped and self.current_time >= self.sequence.duration;
    }
};

// ---------------------------------------------------------------------------
// Track evaluation results — one per track kind
// ---------------------------------------------------------------------------

pub const CameraResult = struct {
    target: []const u8,
    position: [3]f32,
    rotation: [4]f32,
    fov: f32,
};

pub const AnimationResult = struct {
    target: []const u8,
    clip_path: []const u8,
    local_time: f32, // time within the clip
    blend_weight: f32, // 0..1 (handles blend_in/blend_out)
    speed: f32,
};

pub const AudioResult = struct {
    target: []const u8,
    clip_path: []const u8,
    volume: f32, // effective volume (handles fade)
    local_time: f32,
};

pub const EventResult = struct {
    target: []const u8,
    event_name: []const u8,
};

pub const PropertyResult = struct {
    target: []const u8,
    property: []const u8,
    value: f32,
};

pub const EvalResult = struct {
    cameras: []const CameraResult,
    animations: []const AnimationResult,
    audios: []const AudioResult,
    events: []const EventResult,
    properties: []const PropertyResult,
};

// ---------------------------------------------------------------------------
// evaluate()
// ---------------------------------------------------------------------------

/// Evaluate all tracks of a sequence at the given `time`.
/// The caller must free the returned slices via `freeEvalResult`.
pub fn evaluate(allocator: std.mem.Allocator, seq: *const Sequence, time: f32) !EvalResult {
    var cameras = std.ArrayListUnmanaged(CameraResult).empty;
    defer cameras.deinit(allocator);
    var animations = std.ArrayListUnmanaged(AnimationResult).empty;
    defer animations.deinit(allocator);
    var audios = std.ArrayListUnmanaged(AudioResult).empty;
    defer audios.deinit(allocator);
    var events = std.ArrayListUnmanaged(EventResult).empty;
    defer events.deinit(allocator);
    var properties = std.ArrayListUnmanaged(PropertyResult).empty;
    defer properties.deinit(allocator);

    for (seq.tracks.items) |t| {
        switch (t) {
            .camera_path => |cp| {
                const r = cp.evaluate(time);
                try cameras.append(allocator, .{
                    .target = cp.target,
                    .position = r.position,
                    .rotation = r.rotation,
                    .fov = r.fov,
                });
            },
            .animation => |a| {
                if (time >= a.start_time and time <= a.end_time) {
                    const local_t = (time - a.start_time) * a.speed;
                    const clip_duration = a.end_time - a.start_time;
                    var blend: f32 = 1.0;
                    if (a.blend_in > 0 and (time - a.start_time) < a.blend_in) {
                        blend = (time - a.start_time) / a.blend_in;
                    }
                    if (a.blend_out > 0 and (a.end_time - time) < a.blend_out) {
                        blend = @min(blend, (a.end_time - time) / a.blend_out);
                    }
                    _ = clip_duration;
                    try animations.append(allocator, .{
                        .target = a.target,
                        .clip_path = a.clip_path,
                        .local_time = local_t,
                        .blend_weight = blend,
                        .speed = a.speed,
                    });
                }
            },
            .audio => |a| {
                if (time >= a.start_time and time <= a.end_time) {
                    const local_t = time - a.start_time;
                    var vol = a.volume;
                    if (a.fade_in > 0 and local_t < a.fade_in) {
                        vol *= local_t / a.fade_in;
                    }
                    if (a.fade_out > 0 and (a.end_time - time) < a.fade_out) {
                        vol *= (a.end_time - time) / a.fade_out;
                    }
                    try audios.append(allocator, .{
                        .target = a.target,
                        .clip_path = a.clip_path,
                        .volume = vol,
                        .local_time = local_t,
                    });
                }
            },
            .event => |ev| {
                for (ev.events.items) |e| {
                    // Fire events that fall within a small window around `time`.
                    // This is intentionally a point-in-time check; the playback
                    // layer is responsible for tracking which events have been fired.
                    if (@abs(e.time - time) < 0.001) {
                        try events.append(allocator, .{
                            .target = ev.target,
                            .event_name = e.name,
                        });
                    }
                }
            },
            .property => |p| {
                const val = p.evaluate(time);
                try properties.append(allocator, .{
                    .target = p.target,
                    .property = p.property,
                    .value = val,
                });
            },
        }
    }

    return .{
        .cameras = try cameras.toOwnedSlice(allocator),
        .animations = try animations.toOwnedSlice(allocator),
        .audios = try audios.toOwnedSlice(allocator),
        .events = try events.toOwnedSlice(allocator),
        .properties = try properties.toOwnedSlice(allocator),
    };
}

pub fn freeEvalResult(allocator: std.mem.Allocator, result: *EvalResult) void {
    allocator.free(result.cameras);
    allocator.free(result.animations);
    allocator.free(result.audios);
    allocator.free(result.events);
    allocator.free(result.properties);
    result.* = undefined;
}

// ---------------------------------------------------------------------------
// Convenience: evaluate a SequencePlayback
// ---------------------------------------------------------------------------

pub fn evaluatePlayback(allocator: std.mem.Allocator, playback: *const SequencePlayback) !EvalResult {
    return evaluate(allocator, playback.sequence, playback.current_time);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SequencePlayback advance and stop" {
    const alloc = std.testing.allocator;

    var seq = Sequence.init(alloc);
    defer seq.deinit();
    seq.duration = 2.0;

    var pb = SequencePlayback.init(&seq);
    pb.play();

    try std.testing.expect(pb.advance(1.0));
    try std.testing.expectApproxEqAbs(pb.current_time, 1.0, 0.001);

    // Advance past duration → stops
    try std.testing.expect(!pb.advance(1.5));
    try std.testing.expect(pb.isFinished());
}

test "SequencePlayback looping" {
    const alloc = std.testing.allocator;

    var seq = Sequence.init(alloc);
    defer seq.deinit();
    seq.duration = 1.0;

    var pb = SequencePlayback.init(&seq);
    pb.looping = true;
    pb.play();

    try std.testing.expect(pb.advance(1.5));
    // Should wrap around
    try std.testing.expect(pb.current_time < 1.0);
    try std.testing.expect(pb.state == .playing);
}

test "evaluate with property track" {
    const alloc = std.testing.allocator;

    var seq = Sequence.init(alloc);
    defer seq.deinit();
    seq.duration = 5.0;

    var pt = track_mod.PropertyTrack{ .target = "", .property = "" };
    try pt.keyframes.append(alloc, .{ .time = 0.0, .value = 1.0 });
    try pt.keyframes.append(alloc, .{ .time = 5.0, .value = 0.0 });
    try seq.addTrack(.{ .property = pt });

    var result = try evaluate(alloc, &seq, 2.5);
    defer freeEvalResult(alloc, &result);

    try std.testing.expectEqual(@as(usize, 1), result.properties.len);
    try std.testing.expectApproxEqAbs(result.properties[0].value, 0.5, 0.01);
}
