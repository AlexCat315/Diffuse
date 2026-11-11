//! `Editor/Sources/EditorCore/Diagnostics/Rendering/Passes.swift`.

use diffuse_render::core::frame::render_frame_plan::RenderPassKind;
use diffuse_render::core::render_stats::RenderFrameStats;
use serde::{Deserialize, Serialize};

use crate::diagnostics::formatting::format_ns;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperRenderPassInspection {
    pub name: String,
    pub draw_call_count: i64,
    pub encode_ns: u64,
    pub signal: String,
    pub recommendation: String,
}

pub fn make_developer_render_pass_breakdown(
    render_stats: &RenderFrameStats,
) -> Vec<DeveloperRenderPassInspection> {
    let mut pass_names: Vec<RenderPassKind> = Vec::new();
    for pass in &render_stats.active_passes {
        if !pass_names.contains(pass) {
            pass_names.push(*pass);
        }
    }
    let mut draw_call_passes: Vec<RenderPassKind> =
        render_stats.pass_draw_call_counts.keys().copied().collect();
    draw_call_passes.sort_by(|lhs, rhs| lhs.raw_value().cmp(rhs.raw_value()));
    for pass in draw_call_passes {
        if !pass_names.contains(&pass) {
            pass_names.push(pass);
        }
    }
    let mut encode_passes: Vec<RenderPassKind> =
        render_stats.pass_encode_ns.keys().copied().collect();
    encode_passes.sort_by(|lhs, rhs| lhs.raw_value().cmp(rhs.raw_value()));
    for pass in encode_passes {
        if !pass_names.contains(&pass) {
            pass_names.push(pass);
        }
    }

    let mut inspections: Vec<DeveloperRenderPassInspection> = pass_names
        .into_iter()
        .map(|pass| {
            let draws = render_stats
                .pass_draw_call_counts
                .get(&pass)
                .copied()
                .unwrap_or(0);
            let encode_ns = render_stats.pass_encode_ns.get(&pass).copied().unwrap_or(0);
            DeveloperRenderPassInspection {
                name: pass.raw_value().to_string(),
                draw_call_count: draws,
                encode_ns,
                signal: developer_render_pass_signal(pass, draws, encode_ns, render_stats),
                recommendation: developer_render_pass_recommendation(
                    pass,
                    draws,
                    encode_ns,
                    render_stats,
                ),
            }
        })
        .collect();
    inspections.sort_by(|lhs, rhs| {
        if lhs.encode_ns != rhs.encode_ns {
            return rhs.encode_ns.cmp(&lhs.encode_ns);
        }
        if lhs.draw_call_count != rhs.draw_call_count {
            return rhs.draw_call_count.cmp(&lhs.draw_call_count);
        }
        lhs.name.cmp(&rhs.name)
    });
    inspections
}

fn developer_render_pass_signal(
    pass: RenderPassKind,
    draws: i64,
    encode_ns: u64,
    render_stats: &RenderFrameStats,
) -> String {
    if encode_ns > 0 {
        return format!("{} encode, {draws} draws", format_ns(encode_ns));
    }
    if draws > 0 {
        return format!("{draws} draws");
    }
    if pass == RenderPassKind::Particles && render_stats.gpu_particle_render_instance_count > 0 {
        return format!(
            "{} GPU particle instances",
            render_stats.gpu_particle_render_instance_count
        );
    }
    "No measured work".to_string()
}

fn developer_render_pass_recommendation(
    pass: RenderPassKind,
    draws: i64,
    encode_ns: u64,
    render_stats: &RenderFrameStats,
) -> String {
    if encode_ns > 16_700_000 {
        return "Inspect resources and draw submission in this pass before changing global viewport quality."
            .to_string();
    }
    if pass == RenderPassKind::Particles
        && render_stats.gpu_particle_sort_padded_item_count
            > render_stats.gpu_particle_sort_item_count
    {
        return "Check particle sort padding, GPU work split, and render-budget skips in the Particles tool."
            .to_string();
    }
    if draws > 1_000 {
        return "Look for batching, instancing, or culling opportunities tied to this pass."
            .to_string();
    }
    if draws == 0 {
        return "The pass is active but has no submitted draws; verify whether it is required for this frame."
            .to_string();
    }
    "Pass work is measurable; compare it against adjacent passes before tuning content.".to_string()
}
