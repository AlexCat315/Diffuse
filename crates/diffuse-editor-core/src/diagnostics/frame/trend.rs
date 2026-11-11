//! `Editor/Sources/EditorCore/Diagnostics/Frame/Trend.swift`.

use serde::{Deserialize, Serialize};

use crate::diagnostics::formatting::percentile;
use crate::state::editor_state::EditorFrameStatsHistorySample;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperFrameTrendSummary {
    pub sample_count: i64,
    pub first_sample_index: u64,
    pub last_sample_index: u64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub average_observed_fps: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub average_work_fps: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub average_work_ms: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub p95_work_ms: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub max_work_ms: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub average_pacing_gap_ms: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub max_pacing_gap_ms: f64,
    pub pacing_dominated_samples: i64,
    pub peak_work_sample_index: u64,
    pub max_draw_call_count: i64,
    pub max_pass_count: i64,
    pub max_mesh_batch_count: i64,
}

pub fn make_developer_frame_trend_summary(
    history: &[EditorFrameStatsHistorySample],
) -> Option<DeveloperFrameTrendSummary> {
    let first = history.first()?;

    let mut observed_fps_total = 0.0;
    let mut work_fps_total = 0.0;
    let mut work_ms_total = 0.0;
    let mut pacing_gap_ms_total = 0.0;
    let mut max_pacing_gap_ms: f64 = 0.0;
    let mut pacing_dominated_samples = 0;
    let mut max_draw_call_count = 0;
    let mut max_pass_count = 0;
    let mut max_mesh_batch_count = 0;
    let mut peak_work_sample = first;
    let mut work_ms_values = Vec::with_capacity(history.len());

    for sample in history {
        let stats = &sample.stats;
        observed_fps_total += stats.fps;
        work_fps_total += stats.work_fps();
        work_ms_total += stats.work_ms();
        pacing_gap_ms_total += stats.pacing_gap_ms();
        max_pacing_gap_ms = max_pacing_gap_ms.max(stats.pacing_gap_ms());
        if stats.is_frame_pacing_dominated() {
            pacing_dominated_samples += 1;
        }
        if stats.work_ms() > peak_work_sample.stats.work_ms() {
            peak_work_sample = sample;
        }
        max_draw_call_count = max_draw_call_count.max(stats.draw_call_count);
        max_pass_count = max_pass_count.max(stats.pass_count);
        max_mesh_batch_count = max_mesh_batch_count.max(stats.mesh_batch_count);
        work_ms_values.push(stats.work_ms());
    }

    let count = history.len() as f64;
    Some(DeveloperFrameTrendSummary {
        sample_count: history.len() as i64,
        first_sample_index: first.sample_index,
        last_sample_index: history[history.len() - 1].sample_index,
        average_observed_fps: observed_fps_total / count,
        average_work_fps: work_fps_total / count,
        average_work_ms: work_ms_total / count,
        p95_work_ms: percentile(&work_ms_values, 0.95),
        max_work_ms: peak_work_sample.stats.work_ms(),
        average_pacing_gap_ms: pacing_gap_ms_total / count,
        max_pacing_gap_ms,
        pacing_dominated_samples,
        peak_work_sample_index: peak_work_sample.sample_index,
        max_draw_call_count,
        max_pass_count,
        max_mesh_batch_count,
    })
}
