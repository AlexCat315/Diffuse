//! `SequenceDocument+FPS.swift` — remaps every frame range of a document.

use crate::clip_scheduler::{
    remap_frame, remap_frame_count, ClipScheduler, SequenceFPSRemapMode,
};
use crate::sequence_document::{
    Binding, Clip, Cut, FrameRange, Marker, SequenceDocument, Shot, ShotOverride, TimeBase, Track,
};

pub fn remap_sequence_document(
    document: &SequenceDocument,
    source_fps: i64,
    destination_fps: i64,
    mode: SequenceFPSRemapMode,
) -> SequenceDocument {
    let source = TimeBase::with_fps(source_fps);
    let destination = TimeBase::with_fps(destination_fps);

    let remap = |range: FrameRange| -> FrameRange {
        ClipScheduler::remap_frame_range(range, &source, &destination, mode)
    };

    // `remapBinding` is the identity in Swift.
    let remap_binding = |binding: &Binding| -> Binding { binding.clone() };

    let remap_clip = |clip: &Clip| -> Clip {
        let mut result = clip.clone();
        result.shot_range = remap(clip.shot_range);
        result.blend_in_frames =
            remap_frame_count(clip.blend_in_frames, source_fps, destination_fps, mode);
        result.blend_out_frames =
            remap_frame_count(clip.blend_out_frames, source_fps, destination_fps, mode);
        result.bindings = clip.bindings.iter().map(remap_binding).collect();
        result
    };

    let remap_track = |track: &Track| -> Track {
        let mut result = track.clone();
        result.clips = track.clips.iter().map(remap_clip).collect();
        result
    };

    let remap_override = |shot_override: &ShotOverride| -> ShotOverride {
        let mut result = shot_override.clone();
        result.blend_in_frames =
            remap_frame_count(shot_override.blend_in_frames, source_fps, destination_fps, mode);
        result.blend_out_frames =
            remap_frame_count(shot_override.blend_out_frames, source_fps, destination_fps, mode);
        result
    };

    let remap_shot = |shot: &Shot| -> Shot {
        let mut result = shot.clone();
        result.range = remap(shot.range);
        result.overrides = shot.overrides.iter().map(remap_override).collect();
        result.tracks = shot.tracks.iter().map(remap_track).collect();
        result
    };

    let remap_cut = |cut: &Cut| -> Cut {
        let mut result = cut.clone();
        result.frame = remap_frame(cut.frame, source_fps, destination_fps, mode);
        result.duration = remap_frame_count(cut.duration, source_fps, destination_fps, mode);
        result
    };

    let remap_marker = |marker: &Marker| -> Marker {
        let mut result = marker.clone();
        result.frame = remap_frame(marker.frame, source_fps, destination_fps, mode);
        result
    };

    let mut document_out = document.clone();
    document_out.time_base = TimeBase::new(
        destination_fps,
        document.time_base.drop_frame,
        document.time_base.start_timecode,
    );
    document_out.frame_range = remap(document.frame_range);
    document_out.shots = document.shots.iter().map(remap_shot).collect();
    document_out.cuts = document.cuts.iter().map(remap_cut).collect();
    document_out.markers = document.markers.iter().map(remap_marker).collect();
    document_out
}
