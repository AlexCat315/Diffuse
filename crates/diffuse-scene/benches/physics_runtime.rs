//! `PhysicsRuntimeBenchmarks` — Swift `Engine/Benchmarks/PhysicsRuntimeBenchmarks/main.swift`.
//!
//! Standalone executable (`harness = false`). The scenario, body counts and every
//! budget are read from the same `COVE_PHYSICS_*` environment variables as Swift,
//! with the same defaults and clamps. After a warmup the bench ticks a fixed number
//! of frames, records the schedule report (frame, physics, per-phase, step, sync and
//! vertex-stream timings), samples destruction and resident-memory state, prints the
//! same eleven result lines, then applies the same P95/P99 gates and exits non-zero
//! when any gate fails.
//!
//! Timings use `std::time::Instant`, which is the Rust equivalent of Swift's
//! `DispatchTime.now().uptimeNanoseconds`.
//!
//! Swift interpolates two floating-point values directly (`target_fps` and
//! `checksum`). `String(describing:)` prints the shortest round-tripping decimal and
//! keeps a trailing `.0` for integral values; Rust's `Debug` formatting for `f64`
//! and `f32` has the same property, so those fields use `{:?}` while every other
//! number goes through the fixed-precision `milliseconds` formatter.
//!
//! Resident-memory probing has no `libc` dependency in this workspace, so the
//! platform branches declare the few C functions they need. The declarations are
//! `#[cfg]`-gated exactly like Swift's `#if os(...)` branches: Windows uses
//! `K32GetProcessMemoryInfo`, macOS `task_info`, Linux `/proc/self/statm`, and every
//! other platform reports `0`.

use std::collections::BTreeMap;
use std::time::Instant;

use cove_logging::{Level, LogEvent, LogSystem, LoggingConfiguration};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::destruction::{
    Destructible, DestructibleAsset, DestructibleAssetResource, DestructibleConnectionAsset,
    DestructibleFragmentAsset, DestructibleRetainedFragment, DestructionCommand,
    DestructionSettingsResource, DestructionSourceState,
};
use diffuse_scene::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use diffuse_scene::physics::physics_types::PhysicsSimulationMode;
use diffuse_scene::physics::queries::spatial_queries::{
    MeshColliderGeometry, MeshColliderGeometryResource,
};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use diffuse_scene::physics::soft_bodies::cloth::Cloth;
use diffuse_scene::physics::soft_bodies::soft_body::SoftBody;
use diffuse_scene::rendering::render_extraction::RenderMeshComponent;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_scene::scheduling::schedule_commands::RuntimeSystemPhase;

/// `Configuration.Scenario`, raw values included because they are printed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Scenario {
    ActiveGrid,
    DenseContact,
    Cloth64,
    SoftBodyInstances,
    DestructionFragments,
    DestructionIslands,
}

impl Scenario {
    const fn raw_value(&self) -> &'static str {
        match self {
            Scenario::ActiveGrid => "active-grid",
            Scenario::DenseContact => "dense-contact",
            Scenario::Cloth64 => "cloth-64",
            Scenario::SoftBodyInstances => "soft-body-instances",
            Scenario::DestructionFragments => "destruction-fragments",
            Scenario::DestructionIslands => "destruction-islands",
        }
    }

    fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "active-grid" => Some(Scenario::ActiveGrid),
            "dense-contact" => Some(Scenario::DenseContact),
            "cloth-64" => Some(Scenario::Cloth64),
            "soft-body-instances" => Some(Scenario::SoftBodyInstances),
            "destruction-fragments" => Some(Scenario::DestructionFragments),
            "destruction-islands" => Some(Scenario::DestructionIslands),
            _ => None,
        }
    }
}

/// Swift `Configuration`, including the budget derivation in `init(environment:)`.
struct Configuration {
    scenario: Scenario,
    backend: PhysicsBackendKind,
    body_count: i64,
    warmup_frames: i64,
    sample_frames: i64,
    worker_thread_count: i64,
    max_resident_growth_bytes: u64,
    cloth_grid_size: i64,
    max_soft_body_step_nanoseconds: u64,
    max_vertex_stream_nanoseconds: u64,
    max_destruction_activation_nanoseconds: u64,
    max_destruction_step_nanoseconds: u64,
    target_fps: f64,
    max_frame_nanoseconds: u64,
    max_physics_nanoseconds: u64,
}

impl Configuration {
    fn new(environment: &BTreeMap<String, String>) -> Configuration {
        // `min(1_000, max(1, positive(...)))`.
        let target_fps =
            positive(environment, "COVE_PHYSICS_TARGET_FPS", 120.0).clamp(1.0, 1_000.0);
        let frame_budget_ms = 1_000.0 / target_fps;
        // Keep 88% of the frame available to the rest of the engine and game.
        let physics_budget_ms = frame_budget_ms.min(positive(
            environment,
            "COVE_PHYSICS_BUDGET_MS",
            frame_budget_ms * 0.12,
        ));
        let max_frame_nanoseconds = nanoseconds(frame_budget_ms);
        let max_physics_nanoseconds = nanoseconds(physics_budget_ms);

        let scenario = environment
            .get("COVE_PHYSICS_SCENARIO")
            .and_then(|value| Scenario::from_raw_value(value.as_str()))
            .unwrap_or(Scenario::ActiveGrid);
        let backend = environment
            .get("COVE_PHYSICS_BACKEND")
            .and_then(|value| PhysicsBackendKind::from_raw_value(value.as_str()))
            .unwrap_or_else(PhysicsBackendKind::preferred);

        let default_body_count = match scenario {
            Scenario::ActiveGrid => 10_000,
            Scenario::DenseContact => 2_000,
            Scenario::Cloth64 => 1,
            Scenario::SoftBodyInstances => 8,
            Scenario::DestructionFragments | Scenario::DestructionIslands => 4_096,
        };
        let body_count = integer(environment, "COVE_PHYSICS_BODIES", default_body_count).max(1);
        let warmup_frames = integer(environment, "COVE_PHYSICS_WARMUP_FRAMES", 120).max(0);
        let sample_frames = integer(environment, "COVE_PHYSICS_SAMPLE_FRAMES", 600).max(1);
        let worker_thread_count = integer(environment, "COVE_PHYSICS_WORKERS", 0);
        let max_resident_growth_bytes = unsigned(
            environment,
            "COVE_PHYSICS_MAX_RSS_GROWTH_BYTES",
            32 * 1_024 * 1_024,
        );
        let cloth_grid_size = integer(
            environment,
            "COVE_PHYSICS_CLOTH_GRID",
            if scenario == Scenario::Cloth64 {
                64
            } else {
                32
            },
        );

        let step_budget_ms = positive(
            environment,
            "COVE_PHYSICS_SOFT_STEP_BUDGET_MS",
            physics_budget_ms,
        );
        let stream_budget_ms = positive(
            environment,
            "COVE_PHYSICS_VERTEX_STREAM_BUDGET_MS",
            physics_budget_ms * 0.1,
        );
        let max_soft_body_step_nanoseconds = nanoseconds(step_budget_ms.max(0.0));
        let max_vertex_stream_nanoseconds = nanoseconds(stream_budget_ms.max(0.0));

        // Swift converts these two with `Double(_:) ?? default`, so a malformed
        // value falls back but a non-finite one is carried through; `max(0, NaN)`
        // is zero, which `f64::max` reproduces when NaN is the receiver.
        let destruction_budget_ms =
            double(environment, "COVE_PHYSICS_DESTRUCTION_ACTIVATION_BUDGET_MS")
                .unwrap_or(frame_budget_ms);
        let max_destruction_activation_nanoseconds = nanoseconds(destruction_budget_ms.max(0.0));
        let destruction_step_budget_ms =
            double(environment, "COVE_PHYSICS_DESTRUCTION_STEP_BUDGET_MS")
                .unwrap_or(physics_budget_ms);
        let max_destruction_step_nanoseconds = nanoseconds(destruction_step_budget_ms.max(0.0));

        Configuration {
            scenario,
            backend,
            body_count,
            warmup_frames,
            sample_frames,
            worker_thread_count,
            max_resident_growth_bytes,
            cloth_grid_size,
            max_soft_body_step_nanoseconds,
            max_vertex_stream_nanoseconds,
            max_destruction_activation_nanoseconds,
            max_destruction_step_nanoseconds,
            target_fps,
            max_frame_nanoseconds,
            max_physics_nanoseconds,
        }
    }
}

/// `Double(environment[key] ?? "")`, accepted only when finite and positive.
fn positive(environment: &BTreeMap<String, String>, key: &str, fallback: f64) -> f64 {
    match environment
        .get(key)
        .and_then(|value| value.parse::<f64>().ok())
    {
        Some(value) if value.is_finite() && value > 0.0 => value,
        _ => fallback,
    }
}

/// `Int(environment[key] ?? "") ?? fallback`.
fn integer(environment: &BTreeMap<String, String>, key: &str, fallback: i64) -> i64 {
    environment
        .get(key)
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(fallback)
}

/// `Double(environment[key] ?? "")`, with no finiteness filter.
fn double(environment: &BTreeMap<String, String>, key: &str) -> Option<f64> {
    environment
        .get(key)
        .and_then(|value| value.parse::<f64>().ok())
}

/// `UInt64(environment[key] ?? "") ?? fallback`.
fn unsigned(environment: &BTreeMap<String, String>, key: &str, fallback: u64) -> u64 {
    environment
        .get(key)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(fallback)
}

/// `UInt64(milliseconds * 1_000_000)`.
///
/// Swift's initializer traps on negative, non-finite or out-of-range values, so
/// this asserts the same precondition instead of silently saturating.
fn nanoseconds(milliseconds: f64) -> u64 {
    let value = milliseconds * 1_000_000.0;
    assert!(
        value.is_finite() && (0.0..u64::MAX as f64).contains(&value),
        "milliseconds cannot be represented as UInt64"
    );
    value as u64
}

fn make_benchmark_scene(configuration: &Configuration) -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::new());
    runtime.set_physics_settings(PhysicsSettingsResource::new(
        PhysicsSimulationMode::Play,
        configuration.backend,
        if configuration.scenario == Scenario::ActiveGrid {
            Float3::ZERO
        } else {
            Float3::new(0.0, -9.81, 0.0)
        },
        1.0 / 60.0,
        1,
        false,
        1,
        PhysicsCapacitySettings::new(
            16_384_i64.max(configuration.body_count + 16),
            configuration.worker_thread_count,
        ),
    ));

    if configuration.scenario == Scenario::DenseContact {
        let floor = runtime.create_entity();
        let _ = runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, -0.5, 0.0)),
            floor,
        );
        let _ = runtime.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::new(100.0, 0.5, 100.0),
                center: Float3::ZERO,
            }),
            floor,
        );
    }

    match configuration.scenario {
        Scenario::ActiveGrid | Scenario::DenseContact => {
            let active_columns = ((configuration.body_count as f64).sqrt().ceil() as i64).max(1);
            let dense_columns: i64 = 20;
            for index in 0..configuration.body_count {
                let position = if configuration.scenario == Scenario::ActiveGrid {
                    Float3::new(
                        (index % active_columns) as f32 * 1.1 - active_columns as f32 * 0.55,
                        1.0 + (index % 5) as f32 * 1.1,
                        (index / active_columns) as f32 * 1.1 - active_columns as f32 * 0.55,
                    )
                } else {
                    let layer_size = dense_columns * dense_columns;
                    Float3::new(
                        (index % dense_columns) as f32 * 0.92 - dense_columns as f32 * 0.46,
                        0.5 + (index / layer_size) as f32 * 0.92,
                        ((index / dense_columns) % dense_columns) as f32 * 0.92
                            - dense_columns as f32 * 0.46,
                    )
                };
                let entity = runtime.create_entity();
                let _ =
                    runtime.set_local_transform(LocalTransform::from_translation(position), entity);
                let velocity = if configuration.scenario == Scenario::ActiveGrid {
                    Float3::new(0.25, 0.1, 0.15)
                } else {
                    Float3::ZERO
                };
                let _ = runtime.set_component(
                    RigidBody::new(RigidBodyOptions {
                        motion_type: RigidBodyMotionType::Dynamic,
                        mass: 1.0,
                        linear_velocity: velocity,
                        allow_sleep: false,
                        ..Default::default()
                    }),
                    entity,
                );
                let _ = runtime.set_component(
                    Collider::with_shape(ColliderShape::Box {
                        half_extents: Float3::splat(0.5),
                        center: Float3::ZERO,
                    }),
                    entity,
                );
            }
        }
        Scenario::Cloth64 | Scenario::SoftBodyInstances => {
            let grid_size = configuration.cloth_grid_size.clamp(2, 512);
            let instance_count = if configuration.scenario == Scenario::Cloth64 {
                1
            } else {
                configuration.body_count.max(1)
            };
            let columns = ((instance_count as f64).sqrt().ceil() as i64).max(1);
            for index in 0..instance_count {
                let entity = runtime.create_entity();
                let position = Float3::new(
                    (index % columns) as f32 * grid_size as f32 * 0.06,
                    8.0 + (index % 3) as f32,
                    (index / columns) as f32 * grid_size as f32 * 0.06,
                );
                let _ =
                    runtime.set_local_transform(LocalTransform::from_translation(position), entity);
                let _ = runtime
                    .set_component(Cloth::fixed_top_edge(grid_size, grid_size, 0.05), entity);
                let _ = runtime.set_component(
                    SoftBody::new(
                        0.05,
                        0.0,
                        0.05,
                        0.2,
                        0.0,
                        1.0,
                        0.02,
                        5,
                        500.0,
                        0,
                        u16::MAX,
                        false,
                        true,
                        configuration.scenario == Scenario::Cloth64,
                        true,
                    ),
                    entity,
                );
                let _ = runtime.set_component(
                    RenderMeshComponent::new(0, true, Float3::splat(1.0), None, Vec::new()),
                    entity,
                );
            }
        }
        Scenario::DestructionFragments | Scenario::DestructionIslands => {
            let fragments_per_asset: u32 = 16;
            let uses_incremental_islands = configuration.scenario == Scenario::DestructionIslands;
            let geometry = MeshColliderGeometry::new(
                vec![
                    Float3::new(-0.15, -0.15, -0.15),
                    Float3::new(0.15, -0.15, -0.15),
                    Float3::new(0.0, 0.15, -0.15),
                    Float3::new(0.0, 0.0, 0.15),
                ],
                vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
                Vec::new(),
                Vec::new(),
                None,
                0,
            );
            let mut geometry_by_resource_id: BTreeMap<String, MeshColliderGeometry> =
                BTreeMap::new();
            let mut fragment_assets: Vec<DestructibleFragmentAsset> = Vec::new();
            let mut connections: Vec<DestructibleConnectionAsset> = Vec::new();
            for fragment_id in 0..fragments_per_asset {
                let geometry_id = format!("benchmark.destructible.convex.{fragment_id}");
                geometry_by_resource_id.insert(geometry_id.clone(), geometry.clone());
                let x = (fragment_id % 4) as f32 * 0.32 - 0.48;
                let y = ((fragment_id / 4) % 2) as f32 * 0.32 - 0.16;
                let z = (fragment_id / 8) as f32 * 0.32 - 0.16;
                fragment_assets.push(DestructibleFragmentAsset::new(
                    fragment_id,
                    geometry_id,
                    LocalTransform::from_translation(Float3::new(x, y, z)),
                    0.25,
                    if uses_incremental_islands {
                        Some(RenderMeshComponent::new(
                            0,
                            true,
                            Float3::splat(1.0),
                            None,
                            Vec::new(),
                        ))
                    } else {
                        None
                    },
                    None,
                ));
                if fragment_id > 0 {
                    connections.push(DestructibleConnectionAsset::new(
                        fragment_id - 1,
                        fragment_id - 1,
                        fragment_id,
                        0.0,
                        if uses_incremental_islands && fragment_id == 1 {
                            1.0
                        } else {
                            10_000.0
                        },
                    ));
                }
            }
            runtime.set_resource(MeshColliderGeometryResource::new(
                geometry_by_resource_id,
                None,
            ));
            let mut assets = BTreeMap::new();
            assets.insert(
                "benchmark.destructible".to_string(),
                DestructibleAsset::new(0, fragment_assets, connections),
            );
            runtime.set_resource(DestructibleAssetResource::new(assets));
            runtime.set_resource(DestructionSettingsResource::new(
                configuration.body_count,
                1_024_i64.max(configuration.body_count),
            ));

            let activated_fragments_per_source = if uses_incremental_islands {
                fragments_per_asset - 1
            } else {
                fragments_per_asset
            };
            let source_count = ((configuration.body_count as f64)
                / (activated_fragments_per_source as f64))
                .ceil() as i64;
            let columns = ((source_count as f64).sqrt().ceil() as i64).max(1);
            let threshold = if uses_incremental_islands {
                10_000.0
            } else {
                1.0
            };
            for source_index in 0..source_count {
                let entity = runtime.create_entity();
                let _ = runtime.set_local_transform(
                    LocalTransform::from_translation(Float3::new(
                        (source_index % columns) as f32 * 2.0,
                        5.0 + (source_index % 3) as f32 * 2.0,
                        (source_index / columns) as f32 * 2.0,
                    )),
                    entity,
                );
                let _ = runtime.set_component(
                    Collider::with_shape(ColliderShape::Box {
                        half_extents: Float3::new(0.7, 0.4, 0.4),
                        center: Float3::ZERO,
                    }),
                    entity,
                );
                let _ = runtime.set_component(
                    RigidBody::new(RigidBodyOptions {
                        motion_type: RigidBodyMotionType::Static,
                        ..Default::default()
                    }),
                    entity,
                );
                let remaining =
                    configuration.body_count - source_index * activated_fragments_per_source as i64;
                let _ = runtime.set_component(
                    Destructible::new(
                        "benchmark.destructible",
                        threshold,
                        threshold,
                        (activated_fragments_per_source as i64).min(remaining),
                        0.0,
                        0.0,
                        0.25,
                        true,
                    ),
                    entity,
                );
            }
        }
    }
    runtime
}

/// Swift `percentile`: index `Int((count - 1) * fraction)`, clamped to the end.
fn percentile(sorted: &[u64], fraction: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    let last = sorted.len() - 1;
    sorted[(((last as f64) * fraction) as usize).min(last)]
}

/// `String(format: "%.3f", Double(nanoseconds) / 1_000_000)`.
fn milliseconds(nanoseconds: u64) -> String {
    format!("{:.3}", nanoseconds as f64 / 1_000_000.0)
}

/// Elapsed time of `start`, in nanoseconds (`DispatchTime` delta equivalent).
fn elapsed_nanoseconds(start: Instant) -> u64 {
    u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX)
}

/// `ProcessInfo.processInfo.environment`. Non-UTF-8 entries are dropped, matching
/// the `[String: String]` bridge Swift exposes.
fn process_environment() -> BTreeMap<String, String> {
    std::env::vars_os()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .collect()
}

fn check_budget(name: &str, samples: &[u64], budget: u64, failures: &mut Vec<String>) {
    let p95 = percentile(samples, 0.95);
    let p99 = percentile(samples, 0.99);
    if p95 > budget || p99 > budget {
        failures.push(format!(
            "{name} exceeds {} ms: P95={}, P99={}",
            milliseconds(budget),
            milliseconds(p95),
            milliseconds(p99),
        ));
    }
}

fn main() {
    let mut logging_configuration = LoggingConfiguration::default();
    let environment = process_environment();
    logging_configuration
        .apply_environment(&environment)
        .expect("logging configuration");
    LogSystem::bootstrap(None, logging_configuration, None).expect("logging bootstrap");
    run();
    LogSystem::flush();
}

fn run() {
    let environment = process_environment();
    let configuration = Configuration::new(&environment);
    let mut runtime = make_benchmark_scene(&configuration);

    for frame in 0..configuration.warmup_frames {
        let _ = runtime.tick(1.0 / 60.0, frame as u64, Vec::new());
    }
    if matches!(
        configuration.scenario,
        Scenario::DestructionFragments | Scenario::DestructionIslands
    ) {
        let mut entities = runtime.world().entities_with::<Destructible>();
        entities.sort_by_key(|entity| entity.raw_value());
        for entity in entities {
            if configuration.scenario == Scenario::DestructionIslands {
                runtime.submit_destruction_command(DestructionCommand::new(
                    entity,
                    0.0,
                    Float3::new(2.0, 0.0, 0.0),
                    None,
                    false,
                ));
            } else {
                runtime.submit_destruction_command(DestructionCommand::new(
                    entity,
                    0.0,
                    Float3::ZERO,
                    None,
                    true,
                ));
            }
        }
    }

    let capacity = configuration.sample_frames as usize;
    let mut step_samples: Vec<u64> = Vec::with_capacity(capacity);
    let mut frame_samples: Vec<u64> = Vec::with_capacity(capacity);
    let mut physics_samples: Vec<u64> = Vec::with_capacity(capacity);
    let mut phase_samples: BTreeMap<RuntimeSystemPhase, Vec<u64>> = BTreeMap::new();
    let physics_phases: [RuntimeSystemPhase; 5] = [
        RuntimeSystemPhase::FixedPhysicsPrepare,
        RuntimeSystemPhase::FixedPhysicsStep,
        RuntimeSystemPhase::PhysicsWriteback,
        RuntimeSystemPhase::SpatialIndexUpdate,
        RuntimeSystemPhase::TriggerDetection,
    ];
    let mut backend_error_count: i64 = 0;
    let mut sync_samples: Vec<u64> = Vec::with_capacity(capacity);
    let mut contact_total: i64 = 0;
    let mut active_body_peak: i64 = 0;
    let mut active_soft_body_peak: i64 = 0;
    let mut dropped_steps: i64 = 0;
    let mut resident_samples: Vec<u64> = Vec::with_capacity(capacity);
    let mut vertex_stream_samples: Vec<u64> = Vec::with_capacity(capacity);
    let mut streamed_vertex_peak: i64 = 0;
    let mut vertex_checksum: f32 = 0.0;
    let mut active_fragment_peak: i64 = 0;
    let mut destruction_event_total: i64 = 0;
    let mut destruction_activation_nanoseconds: u64 = 0;
    let mut partially_fractured_source_peak: i64 = 0;
    let mut fully_fractured_source_peak: i64 = 0;
    let mut retained_fragment_peak: i64 = 0;
    let mut retained_proxy_peak: i64 = 0;
    let mut compound_root_peak: i64 = 0;

    for offset in 0..configuration.sample_frames {
        let frame = configuration.warmup_frames + offset;
        let frame_started = Instant::now();
        let report = runtime.tick(1.0 / 60.0, frame as u64, Vec::new());
        frame_samples.push(elapsed_nanoseconds(frame_started));
        physics_samples.push(
            physics_phases
                .iter()
                .map(|phase| report.phase_nanoseconds.get(phase).copied().unwrap_or(0))
                .sum(),
        );
        for phase in RuntimeSystemPhase::ALL {
            phase_samples
                .entry(phase)
                .or_default()
                .push(report.phase_nanoseconds.get(&phase).copied().unwrap_or(0));
        }
        if report.physics.error.is_some() {
            backend_error_count += 1;
        }
        if matches!(
            configuration.scenario,
            Scenario::DestructionFragments | Scenario::DestructionIslands
        ) && offset == 0
        {
            destruction_activation_nanoseconds = elapsed_nanoseconds(frame_started);
        }
        step_samples.push(report.physics.step_nanoseconds);
        sync_samples.push(report.physics.synchronization_nanoseconds);
        contact_total += report.physics.contact_count as i64;
        let physics_frame_state = runtime.physics_frame_state();
        active_body_peak = active_body_peak.max(physics_frame_state.active_body_count);
        active_soft_body_peak =
            active_soft_body_peak.max(physics_frame_state.active_soft_body_count);
        dropped_steps += report.physics.dropped_step_count as i64;

        let destruction_frame = runtime.destruction_state_frame();
        active_fragment_peak = active_fragment_peak.max(destruction_frame.active_fragment_count());
        let destruction_events = runtime.destruction_event_frame();
        destruction_event_total += destruction_events.events.len() as i64;
        let destruction_states: Vec<&DestructionSourceState> =
            destruction_frame.sources.values().collect();
        partially_fractured_source_peak = partially_fractured_source_peak.max(
            destruction_states
                .iter()
                .filter(|state| state.has_fractured && !state.is_fully_fractured)
                .count() as i64,
        );
        fully_fractured_source_peak = fully_fractured_source_peak.max(
            destruction_states
                .iter()
                .filter(|state| state.is_fully_fractured)
                .count() as i64,
        );
        retained_fragment_peak = retained_fragment_peak.max(
            destruction_states
                .iter()
                .map(|state| state.retained_fragment_ids.len() as i64)
                .sum::<i64>(),
        );
        retained_proxy_peak = retained_proxy_peak.max(
            runtime
                .world()
                .entities_with::<DestructibleRetainedFragment>()
                .len() as i64,
        );
        let compound_roots = destruction_states
            .iter()
            .filter(|state| {
                if state.is_fully_fractured || !state.has_fractured {
                    return false;
                }
                let Some(collider) = runtime.component::<Collider>(state.source_entity) else {
                    return false;
                };
                collider.shapes.len() == state.retained_fragment_ids.len()
                    && collider
                        .shapes
                        .iter()
                        .zip(state.retained_fragment_ids.iter())
                        .all(|(shape_instance, fragment_id)| {
                            let expected = format!("benchmark.destructible.convex.{fragment_id}");
                            shape_instance.shape.resource_id() == Some(expected.as_str())
                        })
            })
            .count() as i64;
        compound_root_peak = compound_root_peak.max(compound_roots);

        resident_samples.push(memory::resident_bytes());
        let stream_started = Instant::now();
        let deformable_meshes = runtime.render_scene().deformable_meshes;
        streamed_vertex_peak = streamed_vertex_peak.max(
            deformable_meshes
                .iter()
                .map(|mesh| mesh.positions.len() as i64)
                .sum::<i64>(),
        );
        for mesh in &deformable_meshes {
            for position in &mesh.positions {
                vertex_checksum +=
                    position.x * 0.000_001 + position.y * 0.000_002 + position.z * 0.000_003;
            }
        }
        vertex_stream_samples.push(elapsed_nanoseconds(stream_started));
    }

    let mut sorted_steps = step_samples.clone();
    sorted_steps.sort_unstable();
    let mut sorted_frames = frame_samples.clone();
    sorted_frames.sort_unstable();
    let mut sorted_physics = physics_samples.clone();
    sorted_physics.sort_unstable();
    let mut sorted_sync = sync_samples.clone();
    sorted_sync.sort_unstable();
    let mut sorted_vertex_stream = vertex_stream_samples.clone();
    sorted_vertex_stream.sort_unstable();

    let window_size = (configuration.sample_frames / 10).max(1) as usize;
    let mut initial_window = resident_samples[..window_size].to_vec();
    initial_window.sort_unstable();
    let initial_resident = percentile(&initial_window, 0.50);
    let mut final_window = resident_samples[resident_samples.len() - window_size..].to_vec();
    final_window.sort_unstable();
    let final_resident = percentile(&final_window, 0.50);
    let resident_growth = final_resident.saturating_sub(initial_resident);

    let frame_state = runtime.physics_frame_state();
    println!(
        "PhysicsRuntimeBenchmarks backend={} requested_backend={} scenario={} bodies={} workers={} warmup={} frames={}",
        frame_state.backend_identifier,
        configuration.backend.raw_value(),
        configuration.scenario.raw_value(),
        configuration.body_count,
        configuration.worker_thread_count,
        configuration.warmup_frames,
        configuration.sample_frames,
    );
    // `String(describing:)` for `Double`: `Debug` keeps the trailing `.0`.
    println!(
        "target_fps={:?} cpu_tick_budget_ms={} physics_cpu_budget_ms={} full_rendered_frame_verified=false",
        configuration.target_fps,
        milliseconds(configuration.max_frame_nanoseconds),
        milliseconds(configuration.max_physics_nanoseconds),
    );
    println!(
        "cpu_tick_ms p50={} p95={} p99={} max={}",
        milliseconds(percentile(&sorted_frames, 0.50)),
        milliseconds(percentile(&sorted_frames, 0.95)),
        milliseconds(percentile(&sorted_frames, 0.99)),
        milliseconds(sorted_frames.last().copied().unwrap_or(0)),
    );
    println!(
        "physics_cpu_ms p50={} p95={} p99={}",
        milliseconds(percentile(&sorted_physics, 0.50)),
        milliseconds(percentile(&sorted_physics, 0.95)),
        milliseconds(percentile(&sorted_physics, 0.99)),
    );
    for phase in RuntimeSystemPhase::ALL {
        let mut samples = phase_samples.get(&phase).cloned().unwrap_or_default();
        samples.sort_unstable();
        println!(
            "phase_ms phase={} p50={} p95={} p99={}",
            phase.raw_value(),
            milliseconds(percentile(&samples, 0.50)),
            milliseconds(percentile(&samples, 0.95)),
            milliseconds(percentile(&samples, 0.99)),
        );
    }
    println!(
        "step_ms p50={} p95={} p99={}",
        milliseconds(percentile(&sorted_steps, 0.50)),
        milliseconds(percentile(&sorted_steps, 0.95)),
        milliseconds(percentile(&sorted_steps, 0.99)),
    );
    println!(
        "sync_ms p50={} p95={} p99={}",
        milliseconds(percentile(&sorted_sync, 0.50)),
        milliseconds(percentile(&sorted_sync, 0.95)),
        milliseconds(percentile(&sorted_sync, 0.99)),
    );
    // `String(describing:)` for `Float`: `Debug` keeps the trailing `.0`.
    println!(
        "vertex_stream_ms p50={} p95={} p99={} vertices_peak={} checksum={:?}",
        milliseconds(percentile(&sorted_vertex_stream, 0.50)),
        milliseconds(percentile(&sorted_vertex_stream, 0.95)),
        milliseconds(percentile(&sorted_vertex_stream, 0.99)),
        streamed_vertex_peak,
        vertex_checksum,
    );
    println!(
        "contacts_total={} active_body_peak={} active_soft_body_peak={} dropped_steps={} peak_rss_bytes={}",
        contact_total,
        active_body_peak,
        active_soft_body_peak,
        dropped_steps,
        memory::peak_resident_bytes(),
    );
    println!(
        "rss_initial_bytes={} rss_final_bytes={} rss_growth_bytes={}",
        initial_resident, final_resident, resident_growth,
    );
    println!(
        "destruction_activation_ms={} active_fragment_peak={} destruction_events_total={}",
        milliseconds(destruction_activation_nanoseconds),
        active_fragment_peak,
        destruction_event_total,
    );
    println!(
        "destruction_partial_source_peak={} destruction_full_source_peak={} retained_fragment_peak={} retained_proxy_peak={} compound_root_peak={}",
        partially_fractured_source_peak,
        fully_fractured_source_peak,
        retained_fragment_peak,
        retained_proxy_peak,
        compound_root_peak,
    );

    let mut failures: Vec<String> = Vec::new();
    check_budget(
        "CPU tick",
        &sorted_frames,
        configuration.max_frame_nanoseconds,
        &mut failures,
    );
    check_budget(
        "Physics CPU envelope",
        &sorted_physics,
        configuration.max_physics_nanoseconds,
        &mut failures,
    );
    if frame_samples.len() < 100 {
        failures.push("At least 100 measured frames are required for P99 acceptance".to_string());
    }
    if backend_error_count > 0 {
        failures.push(format!(
            "Backend reported errors in {backend_error_count} frames"
        ));
    }
    if dropped_steps > 0 {
        failures.push(format!("Dropped {dropped_steps} fixed steps"));
    }
    if active_soft_body_peak > 0 {
        check_budget(
            "Soft-body step",
            &sorted_steps,
            configuration.max_soft_body_step_nanoseconds,
            &mut failures,
        );
        check_budget(
            "Vertex stream",
            &sorted_vertex_stream,
            configuration.max_vertex_stream_nanoseconds,
            &mut failures,
        );
    }
    if configuration.scenario == Scenario::DestructionFragments
        && (active_fragment_peak != configuration.body_count
            || destruction_activation_nanoseconds
                > configuration.max_destruction_activation_nanoseconds
            || percentile(&sorted_steps, 0.95) > configuration.max_destruction_step_nanoseconds)
    {
        failures.push(
            "Destructible activation missed its fragment count or burst/step budget".to_string(),
        );
    }
    if configuration.scenario == Scenario::DestructionIslands {
        let expected_source_count = (configuration.body_count as f64 / 15.0).ceil() as i64;
        if active_fragment_peak != configuration.body_count
            || partially_fractured_source_peak != expected_source_count
            || fully_fractured_source_peak != 0
            || retained_fragment_peak != expected_source_count
            || retained_proxy_peak != expected_source_count
            || compound_root_peak != expected_source_count
            || destruction_activation_nanoseconds
                > configuration.max_destruction_activation_nanoseconds
            || percentile(&sorted_steps, 0.95) > configuration.max_destruction_step_nanoseconds
        {
            failures.push(
                "Incremental destruction missed its fragment/source/compound/proxy count or burst/step budget"
                    .to_string(),
            );
        }
    }
    if initial_resident > 0
        && final_resident > 0
        && resident_growth > configuration.max_resident_growth_bytes
    {
        failures
            .push("Sustained resident-memory growth exceeded the configured budget".to_string());
    }
    println!(
        "gate_status={} failed_checks={}",
        if failures.is_empty() {
            "passed"
        } else {
            "failed"
        },
        failures.len(),
    );
    for failure in &failures {
        LogSystem::logger("com.cove.tools").log(&LogEvent::new(
            Level::Error,
            format!("Physics benchmark gate failed: {failure}"),
        ));
    }
    LogSystem::flush();
    if !failures.is_empty() {
        std::process::exit(1);
    }
}

/// Process memory, mirroring Swift's `#if os(Windows)` / `#if os(macOS)` /
/// `#elseif os(Linux)` / `#else` branches. Only the fields the bench reads are
/// named; the rest exist so the C functions receive correctly sized buffers.
#[cfg(windows)]
mod memory {
    use std::ffi::c_void;

    type Handle = *mut c_void;
    type Bool = i32;

    /// `PROCESS_MEMORY_COUNTERS`.
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    #[allow(dead_code)]
    struct ProcessMemoryCounters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    }

    // SAFETY: these are the documented kernel32 entry points; their signatures
    // and the `PROCESS_MEMORY_COUNTERS` layout match the Windows SDK.
    #[link(name = "kernel32")]
    unsafe extern "system" {
        #[allow(non_snake_case)]
        fn K32GetProcessMemoryInfo(
            process: Handle,
            counters: *mut ProcessMemoryCounters,
            cb: u32,
        ) -> Bool;
        #[allow(non_snake_case)]
        fn GetCurrentProcess() -> Handle;
    }

    fn process_memory_counters() -> Option<ProcessMemoryCounters> {
        let mut counters = ProcessMemoryCounters {
            cb: std::mem::size_of::<ProcessMemoryCounters>() as u32,
            ..Default::default()
        };
        let size = counters.cb;
        // SAFETY: `counters` is a live, correctly sized `PROCESS_MEMORY_COUNTERS`
        // whose `cb` reports its own size; the pseudo-handle only names this
        // process.
        let succeeded =
            unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size) };
        if succeeded == 0 { None } else { Some(counters) }
    }

    pub fn peak_resident_bytes() -> u64 {
        process_memory_counters()
            .map(|counters| counters.peak_working_set_size as u64)
            .unwrap_or(0)
    }

    pub fn resident_bytes() -> u64 {
        process_memory_counters()
            .map(|counters| counters.working_set_size as u64)
            .unwrap_or(0)
    }
}

#[cfg(unix)]
mod memory {
    /// 64-bit `struct rusage`. Only `ru_maxrss` is read, but every field is
    /// present so `getrusage` writes into a correctly sized buffer. On Darwin
    /// `timeval.tv_usec` is 32-bit with padding, so its leading 32 bytes and the
    /// `ru_maxrss` offset match this layout on every 64-bit target.
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    #[allow(dead_code)]
    struct Rusage {
        ru_utime_seconds: i64,
        ru_utime_microseconds: i64,
        ru_stime_seconds: i64,
        ru_stime_microseconds: i64,
        ru_maxrss: i64,
        ru_ixrss: i64,
        ru_idrss: i64,
        ru_isrss: i64,
        ru_minflt: i64,
        ru_majflt: i64,
        ru_nswap: i64,
        ru_inblock: i64,
        ru_oublock: i64,
        ru_msgsnd: i64,
        ru_msgrcv: i64,
        ru_nsignals: i64,
        ru_nvcsw: i64,
        ru_nivcsw: i64,
    }

    const RUSAGE_SELF: i32 = 0;

    // SAFETY: `getrusage` is the documented POSIX entry point; `Rusage` matches
    // the 64-bit libc layout.
    unsafe extern "C" {
        fn getrusage(who: i32, usage: *mut Rusage) -> i32;
    }

    /// `#if os(Windows) ... #else`: `ru_maxrss` is bytes on macOS and KiB
    /// elsewhere, matching Swift's missing `* 1024` on macOS.
    pub fn peak_resident_bytes() -> u64 {
        let mut usage = Rusage::default();
        // SAFETY: `usage` is a live, correctly laid-out `rusage` and
        // `RUSAGE_SELF` requests only this process's counters.
        let result = unsafe { getrusage(RUSAGE_SELF, &mut usage) };
        if result != 0 {
            return 0;
        }
        #[cfg(target_os = "macos")]
        {
            usage.ru_maxrss as u64
        }
        #[cfg(not(target_os = "macos"))]
        {
            usage.ru_maxrss as u64 * 1_024
        }
    }

    pub fn resident_bytes() -> u64 {
        #[cfg(target_os = "macos")]
        {
            mach::resident_bytes()
        }
        #[cfg(target_os = "linux")]
        {
            linux_resident_bytes()
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            0
        }
    }

    #[cfg(target_os = "macos")]
    mod mach {
        /// `struct time_value`.
        #[repr(C)]
        #[derive(Clone, Copy, Default)]
        #[allow(dead_code)]
        struct TimeValue {
            seconds: i32,
            microseconds: i32,
        }

        /// `mach_task_basic_info`.
        #[repr(C)]
        #[derive(Clone, Copy, Default)]
        #[allow(dead_code)]
        struct MachTaskBasicInfo {
            virtual_size: u64,
            resident_size: u64,
            resident_size_max: u64,
            user_time: TimeValue,
            system_time: TimeValue,
            policy: i32,
            suspend_count: i32,
        }

        const KERN_SUCCESS: i32 = 0;
        const MACH_TASK_BASIC_INFO: u32 = 20;

        // SAFETY: `task_info` and the `mach_task_self_` port are the documented
        // Mach entry points; `MachTaskBasicInfo` matches `mach_task_basic_info`.
        unsafe extern "C" {
            #[allow(non_upper_case_globals)]
            static mach_task_self_: u32;
            fn task_info(
                target_task: u32,
                flavor: u32,
                task_info_out: *mut i32,
                task_info_out_count: *mut u32,
            ) -> i32;
        }

        pub fn resident_bytes() -> u64 {
            let mut info = MachTaskBasicInfo::default();
            let mut count =
                (std::mem::size_of::<MachTaskBasicInfo>() / std::mem::size_of::<u32>()) as u32;
            // SAFETY: `info` is a live, correctly aligned `mach_task_basic_info`,
            // `count` reports its size in `natural_t` units, and
            // `mach_task_self_` is the kernel-provided port for this process.
            let result = unsafe {
                task_info(
                    mach_task_self_,
                    MACH_TASK_BASIC_INFO,
                    &mut info as *mut MachTaskBasicInfo as *mut i32,
                    &mut count,
                )
            };
            if result != KERN_SUCCESS {
                return 0;
            }
            info.resident_size
        }
    }

    #[cfg(target_os = "linux")]
    fn linux_resident_bytes() -> u64 {
        /// `_SC_PAGESIZE` on Linux.
        const SC_PAGESIZE: i32 = 30;

        // SAFETY: `sysconf` is the documented POSIX entry point and `_SC_PAGESIZE`
        // is one of its valid names.
        unsafe extern "C" {
            fn sysconf(name: i32) -> i64;
        }

        let Ok(contents) = std::fs::read_to_string("/proc/self/statm") else {
            return 0;
        };
        let Some(resident_pages) = contents
            .split_whitespace()
            .nth(1)
            .and_then(|value| value.parse::<u64>().ok())
        else {
            return 0;
        };
        // SAFETY: `_SC_PAGESIZE` is a valid `sysconf` name and the call has no
        // memory side effects.
        let page_size = unsafe { sysconf(SC_PAGESIZE) };
        if page_size <= 0 {
            return 0;
        }
        resident_pages * page_size as u64
    }
}

/// Platforms that are neither Windows nor Unix have no probing path, matching
/// Swift's `#else` branch.
#[cfg(not(any(unix, windows)))]
mod memory {
    pub fn peak_resident_bytes() -> u64 {
        0
    }

    pub fn resident_bytes() -> u64 {
        0
    }
}
