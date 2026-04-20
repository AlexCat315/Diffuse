//! Cinematic / Sequencer module for Guava Engine.
//!
//! Provides the data model, interpolation, and evaluation for cinematic sequences
//! (.guava_sequence assets). Sequences can drive camera paths, entity animations,
//! audio clips, timed events, and arbitrary numeric properties.

pub const keyframe = @import("keyframe.zig");
pub const track = @import("track.zig");
pub const camera_path = @import("camera_path.zig");
pub const sequence = @import("sequence.zig");
pub const evaluator = @import("evaluator.zig");
pub const render_output_job = @import("render_output_job.zig");
pub const ffmpeg_encode = @import("ffmpeg_encode.zig");
pub const cutscene_player = @import("cutscene_player.zig");

// Re-export commonly used types at the top level for convenience.
pub const Sequence = sequence.Sequence;
pub const Track = track.Track;
pub const TrackKind = track.TrackKind;
pub const CameraPathTrack = track.CameraPathTrack;
pub const AnimationTrack = track.AnimationTrack;
pub const AudioTrack = track.AudioTrack;
pub const EventTrack = track.EventTrack;
pub const PropertyTrack = track.PropertyTrack;
pub const EasingMode = keyframe.EasingMode;
pub const SequencePlayback = evaluator.SequencePlayback;
pub const PlaybackState = evaluator.PlaybackState;
pub const EvalResult = evaluator.EvalResult;

pub const loadFromJson = sequence.loadFromJson;
pub const loadFromPath = sequence.loadFromPath;
pub const saveToJsonAlloc = sequence.saveToJsonAlloc;
pub const saveToPath = sequence.saveToPath;
pub const evaluate = evaluator.evaluate;
pub const evaluatePlayback = evaluator.evaluatePlayback;
pub const freeEvalResult = evaluator.freeEvalResult;
pub const SequenceRenderJob = render_output_job.SequenceRenderJob;
pub const applyCameraResult = render_output_job.applyCameraResult;
pub const CutscenePlayer = cutscene_player.CutscenePlayer;
pub const CompletionCallback = cutscene_player.CompletionCallback;

// Ensure all tests in submodules are discovered.
comptime {
    _ = keyframe;
    _ = track;
    _ = camera_path;
    _ = sequence;
    _ = evaluator;
    _ = render_output_job;
    _ = ffmpeg_encode;
    _ = cutscene_player;
}
