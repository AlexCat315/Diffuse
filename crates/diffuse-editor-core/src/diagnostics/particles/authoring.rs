//! `Editor/Sources/EditorCore/Diagnostics/Particles/Authoring.swift`.

use std::collections::BTreeMap;

use diffuse_scene::particles::particle_gpu_simulation_plan::{
    ParticleGPUSimulationPlan, ParticleGPUSimulationPlanStatus,
    ParticleGPUSimulationUnsupportedReason,
};
use diffuse_scene::particles::particle_modules::{
    ParticleModuleIssue, ParticleModuleIssueSeverity,
};

use crate::diagnostics::particles::signals::{
    DeveloperParticleDiagnosticSeverity, DeveloperParticleDiagnosticSummary,
    DeveloperParticleEmitterLabel,
};
use crate::scene::models::editor_scene_node::EditorSceneNode;

pub fn make_developer_particle_emitter_labels(
    roots: &[EditorSceneNode],
) -> BTreeMap<u64, DeveloperParticleEmitterLabel> {
    fn visit(
        node: &EditorSceneNode,
        parent_path: Option<&str>,
        labels: &mut BTreeMap<u64, DeveloperParticleEmitterLabel>,
    ) {
        let path = match parent_path {
            Some(parent) => format!("{parent} / {}", node.name),
            None => node.name.clone(),
        };
        labels.insert(
            node.id,
            DeveloperParticleEmitterLabel {
                entity_id: node.id,
                name: node.name.clone(),
                kind: node.kind.clone(),
                path: path.clone(),
            },
        );
        for child in &node.children {
            visit(child, Some(&path), labels);
        }
    }

    let mut labels = BTreeMap::new();
    for root in roots {
        visit(root, None, &mut labels);
    }
    labels
}

pub fn make_developer_particle_authoring_diagnostic_summary(
    gpu_plan: Option<&ParticleGPUSimulationPlan>,
    module_issues: &[ParticleModuleIssue],
) -> DeveloperParticleDiagnosticSummary {
    let mut sorted_issues: Vec<&ParticleModuleIssue> = module_issues.iter().collect();
    sorted_issues.sort_by(|lhs, rhs| developer_particle_module_issue_order(lhs, rhs));
    let error_count = sorted_issues
        .iter()
        .filter(|issue| issue.severity == ParticleModuleIssueSeverity::Error)
        .count();
    let warning_count = sorted_issues
        .iter()
        .filter(|issue| issue.severity == ParticleModuleIssueSeverity::Warning)
        .count();
    let info_count = sorted_issues
        .iter()
        .filter(|issue| issue.severity == ParticleModuleIssueSeverity::Info)
        .count();
    let issue_details = developer_particle_module_issue_details(&sorted_issues, 4);
    let gpu_details = developer_particle_gpu_plan_details(gpu_plan);

    if error_count > 0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Critical,
            status: "Authoring blocked".to_string(),
            primary_signal: format!(
                "{error_count} module {}",
                if error_count == 1 { "error" } else { "errors" }
            ),
            recommendation: "Fix module errors before profiling runtime pressure; blocked GPU-required emitters cannot execute as authored.".to_string(),
            details: [issue_details, gpu_details].concat(),
        };
    }

    if let Some(gpu_plan) = gpu_plan
        && gpu_plan.status == ParticleGPUSimulationPlanStatus::RequiredButUnsupported
    {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Critical,
            status: "GPU simulation blocked".to_string(),
            primary_signal: format!(
                "Unsupported: {}",
                developer_particle_gpu_unsupported_reason_list(&gpu_plan.unsupported_reasons)
            ),
            recommendation: "Remove unsupported modules or switch the backend to GPU If Supported/CPU before relying on this effect.".to_string(),
            details: gpu_details,
        };
    }

    if warning_count > 0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Warning,
            status: "Authoring warnings".to_string(),
            primary_signal: format!(
                "{warning_count} module {}",
                if warning_count == 1 {
                    "warning"
                } else {
                    "warnings"
                }
            ),
            recommendation: "Resolve warnings before chasing frame-time regressions; they often explain CPU fallback or clamped behavior.".to_string(),
            details: [issue_details, gpu_details].concat(),
        };
    }

    if let Some(gpu_plan) = gpu_plan {
        match gpu_plan.status {
            ParticleGPUSimulationPlanStatus::Disabled => {
                return DeveloperParticleDiagnosticSummary {
                    severity: DeveloperParticleDiagnosticSeverity::Nominal,
                    status: "CPU simulation selected".to_string(),
                    primary_signal: "Backend CPU".to_string(),
                    recommendation: "Keep CPU for low-volume emitters; move high-volume compatible effects to GPU If Supported.".to_string(),
                    details: gpu_details,
                };
            }
            ParticleGPUSimulationPlanStatus::Supported => {
                return DeveloperParticleDiagnosticSummary {
                    severity: DeveloperParticleDiagnosticSeverity::Nominal,
                    status: "GPU simulation ready".to_string(),
                    primary_signal: format!(
                        "Dispatch {}x{} for {} capacity",
                        gpu_plan.dispatch_workgroups,
                        gpu_plan.workgroup_size,
                        gpu_plan.particle_capacity
                    ),
                    recommendation: "Track GPU workgroup split, sort padding, and readback drops as effect complexity grows.".to_string(),
                    details: gpu_details,
                };
            }
            ParticleGPUSimulationPlanStatus::FallbackToCpu => {
                return DeveloperParticleDiagnosticSummary {
                    severity: DeveloperParticleDiagnosticSeverity::Warning,
                    status: "GPU fallback to CPU".to_string(),
                    primary_signal: format!(
                        "Unsupported: {}",
                        developer_particle_gpu_unsupported_reason_list(&gpu_plan.unsupported_reasons)
                    ),
                    recommendation: "Remove unsupported features from this emitter or accept CPU simulation for this effect.".to_string(),
                    details: gpu_details,
                };
            }
            ParticleGPUSimulationPlanStatus::RequiredButUnsupported => {
                return DeveloperParticleDiagnosticSummary {
                    severity: DeveloperParticleDiagnosticSeverity::Critical,
                    status: "GPU simulation blocked".to_string(),
                    primary_signal: format!(
                        "Unsupported: {}",
                        developer_particle_gpu_unsupported_reason_list(&gpu_plan.unsupported_reasons)
                    ),
                    recommendation: "Remove unsupported modules or switch the backend to GPU If Supported/CPU before relying on this effect.".to_string(),
                    details: gpu_details,
                };
            }
        }
    }

    if info_count > 0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Info,
            status: "Authoring notes".to_string(),
            primary_signal: format!(
                "{info_count} module {}",
                if info_count == 1 { "note" } else { "notes" }
            ),
            recommendation: "Review module notes when tuning the selected particle emitter."
                .to_string(),
            details: issue_details,
        };
    }

    DeveloperParticleDiagnosticSummary {
        severity: DeveloperParticleDiagnosticSeverity::Idle,
        status: "No selected particle emitter".to_string(),
        primary_signal: "No GPU plan or module issues".to_string(),
        recommendation: "Select a particle emitter to inspect authored backend and module health."
            .to_string(),
        details: Vec::new(),
    }
}

pub fn developer_particle_gpu_unsupported_reason_list(
    reasons: &[ParticleGPUSimulationUnsupportedReason],
) -> String {
    if reasons.is_empty() {
        return "none".to_string();
    }
    reasons
        .iter()
        .map(|reason| developer_particle_gpu_unsupported_reason_label(*reason))
        .collect::<Vec<_>>()
        .join(", ")
}

pub fn developer_particle_gpu_unsupported_reason_label(
    reason: ParticleGPUSimulationUnsupportedReason,
) -> &'static str {
    match reason {
        ParticleGPUSimulationUnsupportedReason::BackendCpu => "CPU backend",
        ParticleGPUSimulationUnsupportedReason::NoParticleCapacity => "no capacity",
        ParticleGPUSimulationUnsupportedReason::EventSubEmitters => "sub-emitters",
        ParticleGPUSimulationUnsupportedReason::DistanceEmission => "distance emission",
        ParticleGPUSimulationUnsupportedReason::Noise => "noise",
        ParticleGPUSimulationUnsupportedReason::ForceFields => "force fields",
        ParticleGPUSimulationUnsupportedReason::Collisions => "collisions",
        ParticleGPUSimulationUnsupportedReason::AngularVelocity => "angular velocity",
    }
}

fn developer_particle_gpu_plan_details(plan: Option<&ParticleGPUSimulationPlan>) -> Vec<String> {
    let Some(plan) = plan else {
        return Vec::new();
    };
    let mut details = vec![
        format!(
            "GPU plan {}",
            developer_particle_gpu_plan_status_label(plan.status)
        ),
        format!(
            "Capacity {}, dispatch {}x{}",
            plan.particle_capacity, plan.dispatch_workgroups, plan.workgroup_size
        ),
    ];
    if !plan.unsupported_reasons.is_empty() {
        details.push(format!(
            "Unsupported {}",
            developer_particle_gpu_unsupported_reason_list(&plan.unsupported_reasons)
        ));
    }
    details
}

fn developer_particle_gpu_plan_status_label(
    status: ParticleGPUSimulationPlanStatus,
) -> &'static str {
    match status {
        ParticleGPUSimulationPlanStatus::Disabled => "CPU",
        ParticleGPUSimulationPlanStatus::Supported => "Ready",
        ParticleGPUSimulationPlanStatus::FallbackToCpu => "Fallback",
        ParticleGPUSimulationPlanStatus::RequiredButUnsupported => "Blocked",
    }
}

fn developer_particle_module_issue_details(
    issues: &[&ParticleModuleIssue],
    limit: i64,
) -> Vec<String> {
    if issues.is_empty() {
        return Vec::new();
    }
    let clipped_limit = limit.max(0) as usize;
    let mut details: Vec<String> = issues
        .iter()
        .take(clipped_limit)
        .map(|issue| {
            format!(
                "{} [{}]: {}",
                issue.module_id,
                issue.severity.raw_value(),
                issue.message
            )
        })
        .collect();
    if issues.len() > clipped_limit {
        details.push(format!(
            "{} more module issues",
            issues.len() - clipped_limit
        ));
    }
    details
}

fn developer_particle_module_issue_order(
    lhs: &ParticleModuleIssue,
    rhs: &ParticleModuleIssue,
) -> std::cmp::Ordering {
    let lhs_rank = developer_particle_module_issue_severity_rank(lhs.severity);
    let rhs_rank = developer_particle_module_issue_severity_rank(rhs.severity);
    if lhs_rank != rhs_rank {
        return rhs_rank.cmp(&lhs_rank);
    }
    if lhs.module_id != rhs.module_id {
        return lhs.module_id.cmp(&rhs.module_id);
    }
    lhs.code.cmp(&rhs.code)
}

fn developer_particle_module_issue_severity_rank(severity: ParticleModuleIssueSeverity) -> i64 {
    match severity {
        ParticleModuleIssueSeverity::Error => 3,
        ParticleModuleIssueSeverity::Warning => 2,
        ParticleModuleIssueSeverity::Info => 1,
    }
}
