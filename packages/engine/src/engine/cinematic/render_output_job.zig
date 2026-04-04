//! Sequence-driven offline rendering job.
//!
//! Evaluates a cinematic Sequence frame-by-frame and applies camera overrides
//! to the scene before each frame is rendered and exported. Integrates with
//! the existing render output state machine in the editor viewport.

const std = @import("std");
const sequence_mod = @import("sequence.zig");
const evaluator_mod = @import("evaluator.zig");
const track_mod = @import("track.zig");
const scene_mod = @import("../scene/world.zig");
const components = @import("../scene/components.zig");

pub const Sequence = sequence_mod.Sequence;
pub const EvalResult = evaluator_mod.EvalResult;
pub const CameraResult = evaluator_mod.CameraResult;

// ---------------------------------------------------------------------------
// SequenceRenderJob — drives per-frame evaluation for offline rendering
// ---------------------------------------------------------------------------

pub const SequenceRenderJob = struct {
    sequence: *Sequence,
    total_frames: u32,
    fps: f32,

    pub fn init(seq: *Sequence) SequenceRenderJob {
        const fps = @max(seq.fps, 1.0);
        const total: u32 = @intFromFloat(@ceil(seq.duration * fps));
        return .{
            .sequence = seq,
            .total_frames = @max(total, 1),
            .fps = fps,
        };
    }

    /// Time in seconds for the given frame index.
    pub fn frameTime(self: *const SequenceRenderJob, frame_index: u32) f32 {
        return @as(f32, @floatFromInt(frame_index)) / self.fps;
    }

    /// Evaluate all tracks at the given frame.
    pub fn evaluateFrame(self: *const SequenceRenderJob, allocator: std.mem.Allocator, frame_index: u32) !EvalResult {
        return evaluator_mod.evaluate(allocator, self.sequence, self.frameTime(frame_index));
    }
};

// ---------------------------------------------------------------------------
// Camera override — apply CameraResult to the scene's primary camera entity
// ---------------------------------------------------------------------------

/// Override the primary camera's transform and FOV using a CameraResult from
/// sequence evaluation. Call this once per frame before the renderer draws.
pub fn applyCameraResult(world: *scene_mod.World, result: CameraResult) void {
    const camera_id = world.primaryCameraEntity() orelse return;
    const entity = world.getEntity(camera_id) orelse return;
    entity.local_transform.translation = result.position;
    entity.local_transform.rotation = result.rotation;
    if (entity.camera) |*cam| {
        switch (cam.projection) {
            .perspective => |*p| {
                // Sequence stores FOV in degrees; convert to radians.
                p.fov_y_radians = result.fov * (std.math.pi / 180.0);
            },
            .orthographic => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SequenceRenderJob frame time" {
    var seq = Sequence.init(std.testing.allocator);
    defer seq.deinit();
    seq.fps = 24.0;
    seq.duration = 2.0;

    const job = SequenceRenderJob.init(&seq);
    try std.testing.expectEqual(@as(u32, 48), job.total_frames);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), job.frameTime(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), job.frameTime(24), 0.001);
}
