//! `ShotEvaluator` — resolves one sequence frame into shot, clips, markers and cut.

use crate::clip_scheduler::{ClipScheduler, ScheduledClip, SequenceEvaluationOptions};
use crate::sequence_document::{Cut, CutTransition, Marker, SequenceDocument, ShotStatus};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvaluatedShot {
    pub shot_id: String,
    pub name: String,
    pub shot_frame: i64,
    pub status: ShotStatus,
}

impl EvaluatedShot {
    #[inline]
    pub fn new(shot_id: String, name: String, shot_frame: i64, status: ShotStatus) -> Self {
        EvaluatedShot {
            shot_id,
            name,
            shot_frame,
            status,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EvaluatedCut {
    pub cut: Cut,
    pub progress: f64,
}

impl EvaluatedCut {
    #[inline]
    pub fn new(cut: Cut, progress: f64) -> Self {
        EvaluatedCut { cut, progress }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EvaluatedSequenceFrame {
    pub sequence_frame: i64,
    pub shot: Option<EvaluatedShot>,
    pub active_clips: Vec<ScheduledClip>,
    pub active_markers: Vec<Marker>,
    pub active_cut: Option<EvaluatedCut>,
}

impl EvaluatedSequenceFrame {
    #[inline]
    pub fn new(
        sequence_frame: i64,
        shot: Option<EvaluatedShot>,
        active_clips: Vec<ScheduledClip>,
        active_markers: Vec<Marker>,
        active_cut: Option<EvaluatedCut>,
    ) -> Self {
        EvaluatedSequenceFrame {
            sequence_frame,
            shot,
            active_clips,
            active_markers,
            active_cut,
        }
    }
}

pub enum ShotEvaluator {}

impl ShotEvaluator {
    pub fn evaluate(
        sequence: &SequenceDocument,
        sequence_frame: i64,
        options: &SequenceEvaluationOptions,
    ) -> EvaluatedSequenceFrame {
        let active_shot = sequence.shot_containing(sequence_frame);
        let evaluated_shot = active_shot.and_then(|shot| {
            let shot_frame = ClipScheduler::shot_frame(sequence_frame, shot)?;
            Some(EvaluatedShot::new(
                shot.id.clone(),
                shot.name.clone(),
                shot_frame,
                shot.status,
            ))
        });

        EvaluatedSequenceFrame::new(
            sequence_frame,
            evaluated_shot,
            active_shot
                .map(|shot| ClipScheduler::active_clips(shot, sequence_frame, options))
                .unwrap_or_default(),
            sequence
                .markers_at(sequence_frame)
                .into_iter()
                .cloned()
                .collect(),
            Self::active_cut(sequence, sequence_frame),
        )
    }

    pub fn active_cut(sequence: &SequenceDocument, sequence_frame: i64) -> Option<EvaluatedCut> {
        let active_cuts: Vec<&Cut> = sequence
            .cuts
            .iter()
            .filter(|cut| match cut.transition {
                CutTransition::Hard => cut.frame == sequence_frame,
                CutTransition::Dissolve
                | CutTransition::FadeIn
                | CutTransition::FadeOut
                | CutTransition::Wipe => {
                    let duration = cut.duration.max(1);
                    sequence_frame >= cut.frame && sequence_frame < cut.frame + duration
                }
            })
            .collect();

        let mut ordered = active_cuts;
        ordered.sort_by_key(|cut| std::cmp::Reverse(cut.frame));
        let cut = ordered.first()?;
        let progress = if cut.transition == CutTransition::Hard || cut.duration <= 0 {
            1.0
        } else {
            ((sequence_frame - cut.frame) as f64 / cut.duration as f64).clamp(0.0, 1.0)
        };
        Some(EvaluatedCut::new((*cut).clone(), progress))
    }
}
