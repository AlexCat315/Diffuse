//! `ClipScheduler` — maps sequence frames into shot and source time.

use crate::sequence_document::{Clip, FrameRange, Shot, TimeBase, TrackKind};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SequenceFPSRemapMode {
    PreserveDurationRatio,
    PreserveFrameCount,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SequenceEvaluationOptions {
    pub solo_track_ids: std::collections::BTreeSet<String>,
}

impl SequenceEvaluationOptions {
    #[inline]
    pub fn new(solo_track_ids: std::collections::BTreeSet<String>) -> Self {
        SequenceEvaluationOptions { solo_track_ids }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScheduledClip {
    pub shot_id: String,
    pub track_id: String,
    pub track_kind: TrackKind,
    pub clip_id: String,
    pub sequence_frame: i64,
    pub shot_frame: i64,
    pub source_frame: f64,
    pub weight: f64,
}

impl ScheduledClip {
    #[allow(clippy::too_many_arguments)]
    #[inline]
    pub fn new(
        shot_id: String,
        track_id: String,
        track_kind: TrackKind,
        clip_id: String,
        sequence_frame: i64,
        shot_frame: i64,
        source_frame: f64,
        weight: f64,
    ) -> Self {
        ScheduledClip {
            shot_id,
            track_id,
            track_kind,
            clip_id,
            sequence_frame,
            shot_frame,
            source_frame,
            weight,
        }
    }
}

pub enum ClipScheduler {}

impl ClipScheduler {
    pub fn shot_frame(sequence_frame: i64, shot: &Shot) -> Option<i64> {
        if !shot.range.contains(sequence_frame) {
            return None;
        }
        Some(sequence_frame - shot.range.start + shot.source_offset)
    }

    pub fn source_frame(shot_frame: i64, clip: &Clip) -> Option<f64> {
        if !clip.enabled || !clip.shot_range.contains(shot_frame) || clip.time_warp < 0.0 {
            return None;
        }
        if clip.time_warp == 0.0 {
            return Some(clip.source_offset as f64);
        }
        let local_frame = shot_frame - clip.shot_range.start;
        Some(clip.source_offset as f64 + local_frame as f64 * clip.time_warp)
    }

    pub fn clip_is_valid(clip: &Clip, shot: &Shot) -> bool {
        if shot.range.duration() < 0 {
            return false;
        }
        if !shot.range.contains_range(FrameRange::new(
            shot.range.start + clip.shot_range.start,
            shot.range.start + clip.shot_range.end,
        )) {
            return false;
        }
        if clip.time_warp < 0.0 {
            return false;
        }
        clip.blend_in_frames + clip.blend_out_frames <= clip.shot_range.duration()
    }

    pub fn active_clips(
        shot: &Shot,
        sequence_frame: i64,
        options: &SequenceEvaluationOptions,
    ) -> Vec<ScheduledClip> {
        let Some(shot_frame) = Self::shot_frame(sequence_frame, shot) else {
            return Vec::new();
        };

        let active_solo_ids: std::collections::BTreeSet<String> =
            if options.solo_track_ids.is_empty() {
                shot.tracks
                    .iter()
                    .filter(|track| track.solo)
                    .map(|track| track.id.clone())
                    .collect()
            } else {
                options.solo_track_ids.clone()
            };

        let mut result = Vec::new();
        for track in &shot.tracks {
            if track.mute {
                continue;
            }
            if !active_solo_ids.is_empty() && !active_solo_ids.contains(&track.id) {
                continue;
            }

            for clip in track
                .clips
                .iter()
                .filter(|clip| clip.enabled && clip.shot_range.contains(shot_frame))
            {
                if !Self::clip_is_valid(clip, shot) {
                    continue;
                }
                let Some(source_frame) = Self::source_frame(shot_frame, clip) else {
                    continue;
                };
                result.push(ScheduledClip::new(
                    shot.id.clone(),
                    track.id.clone(),
                    track.kind,
                    clip.id.clone(),
                    sequence_frame,
                    shot_frame,
                    source_frame,
                    clip.weight * Self::blend_weight(shot_frame, clip),
                ));
            }
        }
        result
    }

    pub fn remap_frame_range(
        range: FrameRange,
        source: &TimeBase,
        destination: &TimeBase,
        mode: SequenceFPSRemapMode,
    ) -> FrameRange {
        match mode {
            SequenceFPSRemapMode::PreserveFrameCount => range,
            SequenceFPSRemapMode::PreserveDurationRatio => {
                let ratio = destination.fps as f64 / source.fps.max(1) as f64;
                let mapped_start = (range.start as f64 * ratio).round() as i64;
                let mapped_end = (range.end as f64 * ratio).round() as i64;
                FrameRange::new(mapped_start, mapped_start.max(mapped_end))
            }
        }
    }

    fn blend_weight(shot_frame: i64, clip: &Clip) -> f64 {
        let mut weight: f64 = 1.0;
        let local_frame = shot_frame - clip.shot_range.start;

        if clip.blend_in_frames > 0 {
            let in_weight = (local_frame as f64 / clip.blend_in_frames as f64).clamp(0.0, 1.0);
            weight = weight.min(in_weight);
        }
        if clip.blend_out_frames > 0 {
            let remaining_frames = (clip.shot_range.end - shot_frame).max(0);
            let out_weight =
                (remaining_frames as f64 / clip.blend_out_frames as f64).clamp(0.0, 1.0);
            weight = weight.min(out_weight);
        }
        weight
    }
}

/// Swift's `SequenceDocument.remapping` counterpart; kept beside the scheduler
/// because it reuses `remap_frame_range` and `remap_frame_count`.
pub(crate) fn remap_frame_count(
    count: i64,
    source_fps: i64,
    destination_fps: i64,
    mode: SequenceFPSRemapMode,
) -> i64 {
    match mode {
        SequenceFPSRemapMode::PreserveFrameCount => count,
        SequenceFPSRemapMode::PreserveDurationRatio => {
            let ratio = destination_fps as f64 / source_fps.max(1) as f64;
            (count as f64 * ratio).round() as i64
        }
    }
}

pub(crate) fn remap_frame(
    frame: i64,
    source_fps: i64,
    destination_fps: i64,
    mode: SequenceFPSRemapMode,
) -> i64 {
    remap_frame_count(frame, source_fps, destination_fps, mode)
}
