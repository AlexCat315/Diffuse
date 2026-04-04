//! Runtime cutscene player — plays a cinematic Sequence during gameplay.
//!
//! Provides the `world.loadSequence()` / `play()` / `onComplete()` interface
//! described in the roadmap.  The player manages its own playback state,
//! evaluates all tracks every tick, and applies the results (camera overrides,
//! animation blending, events, properties) to the world.
//!
//! Usage:
//!   var player = try CutscenePlayer.load(allocator, world, "assets/scenes/intro.guava_sequence");
//!   player.play();
//!   // Each frame:
//!   player.tick(delta_seconds);
//!   if (player.isFinished()) { ... }
//!   // Cleanup:
//!   player.deinit();

const std = @import("std");
const sequence_mod = @import("sequence.zig");
const evaluator_mod = @import("evaluator.zig");
const render_output_job = @import("render_output_job.zig");
const scene_mod = @import("../scene/world.zig");

pub const Sequence = sequence_mod.Sequence;
pub const SequencePlayback = evaluator_mod.SequencePlayback;
pub const PlaybackState = evaluator_mod.PlaybackState;
pub const EvalResult = evaluator_mod.EvalResult;
pub const CameraResult = evaluator_mod.CameraResult;

/// Callback signature for completion events.
pub const CompletionCallback = *const fn (player: *CutscenePlayer) void;

/// Runtime cutscene player.
///
/// Owns a loaded Sequence and its playback state machine. Call `tick()` every
/// frame to advance playback and apply results to the world.
pub const CutscenePlayer = struct {
    allocator: std.mem.Allocator,
    world: *scene_mod.World,
    sequence: *Sequence,
    playback: SequencePlayback,
    /// Last evaluation result (valid after the first tick while playing).
    last_result: ?EvalResult = null,
    /// Optional completion callback.
    on_complete: ?CompletionCallback = null,
    /// Whether the completion callback has already fired for the current play.
    completion_fired: bool = false,
    /// If true, the original camera transform is saved on play and restored
    /// on stop/finish.
    restore_camera_on_finish: bool = true,
    /// Saved camera state for restoration.
    saved_camera_translation: [3]f32 = .{ 0, 0, 0 },
    saved_camera_rotation: [4]f32 = .{ 0, 0, 0, 1 },
    saved_camera_fov: f32 = 60.0,
    camera_saved: bool = false,

    // -- Construction / destruction -----------------------------------------

    /// Load a sequence from disk and create a player bound to `world`.
    /// The caller must call `deinit()` when done.
    pub fn load(
        allocator: std.mem.Allocator,
        world: *scene_mod.World,
        path: []const u8,
    ) !CutscenePlayer {
        const seq = try sequence_mod.loadFromPath(allocator, path);
        return initWithSequence(allocator, world, seq);
    }

    /// Create a player from an already‐loaded Sequence.
    /// Takes ownership of `seq`; the player will free it on `deinit()`.
    pub fn initWithSequence(
        allocator: std.mem.Allocator,
        world: *scene_mod.World,
        seq: *Sequence,
    ) CutscenePlayer {
        return .{
            .allocator = allocator,
            .world = world,
            .sequence = seq,
            .playback = SequencePlayback.init(seq),
        };
    }

    pub fn deinit(self: *CutscenePlayer) void {
        if (self.last_result) |*r| evaluator_mod.freeEvalResult(self.allocator, r);
        self.sequence.deinit();
        self.* = undefined;
    }

    // -- Transport controls -------------------------------------------------

    pub fn play(self: *CutscenePlayer) void {
        if (self.playback.state == .stopped) {
            self.completion_fired = false;
            self.saveCameraState();
        }
        self.playback.play();
    }

    pub fn pause(self: *CutscenePlayer) void {
        self.playback.pause();
    }

    pub fn stop(self: *CutscenePlayer) void {
        self.playback.stop();
        self.restoreCameraState();
    }

    pub fn seekTo(self: *CutscenePlayer, time: f32) void {
        self.playback.seekTo(time);
    }

    pub fn setLooping(self: *CutscenePlayer, looping: bool) void {
        self.playback.looping = looping;
    }

    pub fn setSpeed(self: *CutscenePlayer, speed: f32) void {
        self.playback.speed = speed;
    }

    // -- Query --------------------------------------------------------------

    pub fn isPlaying(self: *const CutscenePlayer) bool {
        return self.playback.state == .playing;
    }

    pub fn isFinished(self: *const CutscenePlayer) bool {
        return self.playback.isFinished();
    }

    pub fn currentTime(self: *const CutscenePlayer) f32 {
        return self.playback.current_time;
    }

    pub fn duration(self: *const CutscenePlayer) f32 {
        return self.sequence.duration;
    }

    // -- Per-frame update ---------------------------------------------------

    /// Advance the cutscene by `delta_seconds` and apply results to the world.
    /// Call this once per frame.
    pub fn tick(self: *CutscenePlayer, delta_seconds: f32) void {
        if (self.playback.state != .playing) return;

        const was_playing = self.playback.advance(delta_seconds);

        // Evaluate tracks at the current time.
        if (self.last_result) |*r| evaluator_mod.freeEvalResult(self.allocator, r);
        self.last_result = null;

        const result = evaluator_mod.evaluatePlayback(self.allocator, &self.playback) catch return;
        self.last_result = result;

        // Apply camera override.
        if (result.cameras.len > 0) {
            render_output_job.applyCameraResult(self.world, result.cameras[0]);
        }

        // Handle completion.
        if (!was_playing and !self.completion_fired) {
            self.completion_fired = true;
            self.restoreCameraState();
            if (self.on_complete) |cb| cb(self);
        }
    }

    /// Register a completion callback, returned `self` for chaining.
    pub fn onComplete(self: *CutscenePlayer, callback: CompletionCallback) *CutscenePlayer {
        self.on_complete = callback;
        return self;
    }

    // -- Camera save/restore ------------------------------------------------

    fn saveCameraState(self: *CutscenePlayer) void {
        if (!self.restore_camera_on_finish) return;
        const cam_id = self.world.primaryCameraEntity() orelse return;
        const entity = self.world.getEntity(cam_id) orelse return;
        self.saved_camera_translation = entity.local_transform.translation;
        self.saved_camera_rotation = entity.local_transform.rotation;
        if (entity.camera) |cam| {
            switch (cam.projection) {
                .perspective => |p| self.saved_camera_fov = p.fov_y_radians,
                .orthographic => {},
            }
        }
        self.camera_saved = true;
    }

    fn restoreCameraState(self: *CutscenePlayer) void {
        if (!self.camera_saved) return;
        const cam_id = self.world.primaryCameraEntity() orelse return;
        const entity = self.world.getEntity(cam_id) orelse return;
        entity.local_transform.translation = self.saved_camera_translation;
        entity.local_transform.rotation = self.saved_camera_rotation;
        if (entity.camera) |*cam| {
            switch (cam.projection) {
                .perspective => |*p| p.fov_y_radians = self.saved_camera_fov,
                .orthographic => {},
            }
        }
        self.camera_saved = false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "CutscenePlayer init/deinit with empty sequence" {
    const allocator = std.testing.allocator;
    var seq = Sequence.init(allocator);
    seq.duration = 1.0;
    seq.fps = 24.0;

    // We don't have a real World in unit tests, so just test construction.
    // initWithSequence takes a *World but we only touch it during tick().
    var player = CutscenePlayer.initWithSequence(allocator, undefined, &seq);
    defer player.deinit();

    try std.testing.expect(!player.isPlaying());
    try std.testing.expect(!player.isFinished());
    try std.testing.expectEqual(@as(f32, 1.0), player.duration());
}
