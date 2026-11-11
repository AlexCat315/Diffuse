//! `Editor/Sources/EditorCore/Diagnostics/Formatting.swift`.
//!
//! Human-readable strings for the developer panels. Swift used
//! `String(format:)`; the Rust `format!` precision specifiers produce the same
//! PDF-style decimal text for these ranges.

use diffuse_render::core::render_stats::RenderFrameStats;
use diffuse_scene::rendering::render_scene::ParticleRenderSummary;

use crate::state::editor_state::{
    EditorFrameStats, EditorFrameStatsHistorySample, EditorParticleDiagnosticsSample,
};

pub fn format_fps(fps: f64) -> String {
    if fps <= 0.0 {
        return "--".to_string();
    }
    if fps >= 1000.0 {
        return "---".to_string();
    }
    format!("{fps:.0}")
}

pub fn format_ms(ms: f64) -> String {
    if ms <= 0.0 {
        return "--ms".to_string();
    }
    if ms < 10.0 {
        return format!("{ms:.2}ms");
    }
    if ms < 100.0 {
        return format!("{ms:.1}ms");
    }
    format!("{ms:.0}ms")
}

pub fn format_ns(ns: u64) -> String {
    if ns == 0 {
        return "--".to_string();
    }
    let ms = ns as f64 / 1_000_000.0;
    if ms < 0.01 {
        return format!("{ms:.3}ms");
    }
    if ms < 10.0 {
        return format!("{ms:.2}ms");
    }
    if ms < 100.0 {
        return format!("{ms:.1}ms");
    }
    format!("{ms:.0}ms")
}

pub fn format_byte_count(bytes: u64) -> String {
    if bytes == 0 {
        return "0 B".to_string();
    }
    if bytes < 1_024 {
        return format!("{bytes} B");
    }
    let kib = bytes as f64 / 1_024.0;
    if kib < 1_024.0 {
        return format!("{kib:.1} KiB");
    }
    format!("{:.1} MiB", kib / 1_024.0)
}

pub fn format_signed_ms(ms: f64) -> String {
    if !ms.is_finite() {
        return "--ms".to_string();
    }
    if ms == 0.0 {
        return "0.00ms".to_string();
    }
    let prefix = if ms > 0.0 { "+" } else { "-" };
    format!("{prefix}{}", format_ms(ms.abs()))
}

pub fn gpu_particle_workgroup_total(stats: &RenderFrameStats) -> i64 {
    stats.gpu_particle_simulation_dispatch_workgroups
        + stats.gpu_particle_sort_dispatch_workgroups
        + stats.gpu_particle_instance_dispatch_workgroups
        + stats.gpu_particle_cull_dispatch_workgroups
}

pub fn particle_average_batch_size(summary: &ParticleRenderSummary) -> f64 {
    if summary.batch_count <= 0 {
        return 0.0;
    }
    summary.particle_count as f64 / summary.batch_count as f64
}

pub fn particle_sort_padding_overhead(stats: &RenderFrameStats) -> f64 {
    if stats.gpu_particle_sort_padded_item_count <= 0
        || stats.gpu_particle_sort_padded_item_count < stats.gpu_particle_sort_item_count
    {
        return 0.0;
    }
    let padding = stats.gpu_particle_sort_padded_item_count - stats.gpu_particle_sort_item_count;
    padding as f64 / stats.gpu_particle_sort_padded_item_count as f64
}

/// Swift's second overload of `particleSortPaddingOverhead(_:)`.
pub fn particle_sort_padding_overhead_for_sample(sample: &EditorParticleDiagnosticsSample) -> f64 {
    if sample.gpu_sort_padded_item_count <= 0
        || sample.gpu_sort_padded_item_count < sample.gpu_sort_item_count
    {
        return 0.0;
    }
    let padding = sample.gpu_sort_padded_item_count - sample.gpu_sort_item_count;
    padding as f64 / sample.gpu_sort_padded_item_count as f64
}

pub fn percentile(values: &[f64], fraction: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let clamped_fraction = fraction.clamp(0.0, 1.0);
    let mut sorted_values = values.to_vec();
    sorted_values.sort_by(f64::total_cmp);
    let raw_index = clamped_fraction * (sorted_values.len() - 1) as f64;
    let index = raw_index.ceil() as i64;
    let index = index.clamp(0, sorted_values.len() as i64 - 1);
    sorted_values[index as usize]
}

pub fn format_percent(numerator: i64, denominator: i64) -> String {
    if denominator <= 0 {
        return "--".to_string();
    }
    let percent = numerator as f64 / denominator as f64 * 100.0;
    if percent < 10.0 {
        return format!("{percent:.1}%");
    }
    format!("{percent:.0}%")
}

pub fn format_percent_fraction(value: f64) -> String {
    if !value.is_finite() {
        return "--".to_string();
    }
    let percent = value * 100.0;
    if percent < 10.0 {
        return format!("{percent:.1}%");
    }
    format!("{percent:.0}%")
}

pub fn format_budget(used: i64, limit: i64) -> String {
    if limit > 0 {
        format!("{used}/{limit}")
    } else {
        format!("{used}/unlimited")
    }
}

pub fn format_decimal(value: f64) -> String {
    if !value.is_finite() {
        return "--".to_string();
    }
    if value >= 10.0 {
        return format!("{value:.0}");
    }
    format!("{value:.1}")
}

pub fn format_scale(value: f32) -> String {
    if !value.is_finite() {
        return "--".to_string();
    }
    format!("{value:.2}")
}

pub fn cpu_ms(stats: &EditorFrameStats) -> f64 {
    stats.cpu_work_seconds() * 1000.0
}

fn budget_status(frame_ms: f64, target_ms: f64) -> String {
    if frame_ms <= 0.0 {
        return "--".to_string();
    }
    if frame_ms <= target_ms {
        return "OK".to_string();
    }
    format!("+{}", format_ms(frame_ms - target_ms))
}

pub fn bottleneck(stats: &EditorFrameStats) -> String {
    let cpu = cpu_ms(stats);
    let gpu = stats.gpu_present_seconds * 1000.0;
    if stats.work_ms() <= 0.0 {
        return "--".to_string();
    }
    if cpu <= 0.0 && gpu <= 0.0 {
        return "Frame pacing".to_string();
    }
    if stats.is_frame_pacing_dominated() {
        return "Frame pacing / idle".to_string();
    }
    if cpu > gpu * 1.25 {
        return "CPU".to_string();
    }
    if gpu > cpu * 1.25 {
        return "GPU / present".to_string();
    }
    "Mixed".to_string()
}

fn average_draws_per_pass(stats: &EditorFrameStats) -> String {
    if stats.pass_count <= 0 {
        return "--".to_string();
    }
    let average = stats.draw_call_count as f64 / stats.pass_count as f64;
    if average < 10.0 {
        return format!("{average:.1}");
    }
    format!("{average:.0}")
}

fn selected_frame_sample(
    history: &[EditorFrameStatsHistorySample],
    selected_sample_index: Option<u64>,
) -> Option<&EditorFrameStatsHistorySample> {
    if let Some(index) = selected_sample_index
        && let Some(sample) = history.iter().find(|sample| sample.sample_index == index)
    {
        return Some(sample);
    }
    history.last()
}

pub fn frame_budget_glyph(stats: &EditorFrameStats) -> String {
    if stats.is_frame_pacing_dominated() {
        return "P".to_string();
    }
    if stats.work_ms() > 33.3 {
        return "!".to_string();
    }
    if stats.work_ms() > 16.7 {
        return "*".to_string();
    }
    ".".to_string()
}
