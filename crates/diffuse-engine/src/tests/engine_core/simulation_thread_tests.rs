//! Ported from `Engine/Tests/EngineCoreTests/SimulationThreadTests.swift`.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::engine_core::EngineRuntime;
use crate::latest_value_buffer::LatestValueBuffer;
use crate::simulation_thread::{SimulationFrameRequest, SimulationThread};
use diffuse_kernel::engine_kernel::{EngineKernelPhase, EngineKernelPhaseContext};
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_kernel::input_event::{InputEvent, MouseMotionEvent};
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::render_stats::{
    GPUParticleSimulationEventRecord, GPUParticleSimulationEventSnapshot,
    GPUParticleSimulationEventTrigger,
};
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{JointPalette, JointPaletteMap};
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use diffuse_scene::particles::particle_types::ParticleSubEmitterTrigger;
use diffuse_scene::rendering::render_scene::RenderCamera;
use diffuse_scene::scene_runtime::{SceneRuntime, SceneRuntimeSnapshot};

struct IdleRuntime;
impl EngineRuntime for IdleRuntime {
    fn initialize(&self) {}
    fn tick_input(&self, _delta_time: f64, _input_events: &[InputEvent]) {}
    fn tick_simulation(&self, _delta_time: f64) {}
    fn tick_render_prepare(&self, _delta_time: f64) {}
    fn tick_render_submit(&self, _delta_time: f64) {}
    fn shutdown(&self) {}
}

/// Counting signal standing in for `DispatchSemaphore(value: 0)`.
struct Signal {
    count: Mutex<usize>,
    condvar: Condvar,
}

impl Signal {
    fn new() -> Self {
        Signal {
            count: Mutex::new(0),
            condvar: Condvar::new(),
        }
    }

    fn signal(&self) {
        *self
            .count
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) += 1;
        self.condvar.notify_all();
    }

    fn wait(&self, timeout: Duration) -> bool {
        let mut count = self
            .count
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if *count > 0 {
            *count -= 1;
            return true;
        }
        let deadline = std::time::Instant::now() + timeout;
        while *count == 0 {
            let now = std::time::Instant::now();
            if now >= deadline {
                return false;
            }
            let (guard, _) = self
                .condvar
                .wait_timeout(count, deadline - now)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            count = guard;
        }
        *count -= 1;
        true
    }
}

struct RecordingRuntime {
    last_input: Mutex<Option<(f64, usize)>>,
}

impl RecordingRuntime {
    fn new() -> Self {
        RecordingRuntime {
            last_input: Mutex::new(None),
        }
    }

    fn last_input_call(&self) -> Option<(f64, usize)> {
        *self
            .last_input
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl EngineRuntime for RecordingRuntime {
    fn initialize(&self) {}

    fn tick_input(&self, delta_time: f64, input_events: &[InputEvent]) {
        *self
            .last_input
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((delta_time, input_events.len()));
    }

    fn tick_simulation(&self, _delta_time: f64) {}
    fn tick_render_prepare(&self, _delta_time: f64) {}
    fn tick_render_submit(&self, _delta_time: f64) {}
    fn shutdown(&self) {}
}

type PhaseLog = Arc<Mutex<Vec<(EngineKernelPhase, EngineKernelPhaseContext)>>>;

fn frame_request(frame_index: i64, drawable_size: RenderDrawableSize) -> SimulationFrameRequest {
    SimulationFrameRequest::new(
        frame_index,
        1.0 / 60.0,
        Vec::new(),
        drawable_size,
        true,
        RenderSettings::new(),
        None,
        None,
        None,
        None,
        false,
    )
}

fn translation(matrix: &diffuse_math::simd::simd_compat::Float4x4) -> Float3 {
    Float3::new(
        matrix.columns[3].x,
        matrix.columns[3].y,
        matrix.columns[3].z,
    )
}

/// SimulationThread publishes render packets extracted from SceneRuntime.
#[test]
fn simulation_thread_publishes_extracted_scene() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let frame_ready = Arc::new(Signal::new());
    let packet_published = Arc::new(Signal::new());

    let frame_ready_signal = frame_ready.clone();
    let packet_signal = packet_published.clone();
    let thread = SimulationThread::new(
        Arc::new(IdleRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        Arc::new(move |_| frame_ready_signal.signal()),
        Arc::new(|_| {}),
        Arc::new(move || packet_signal.signal()),
        None,
    );

    thread.submit(frame_request(0, RenderDrawableSize::new(1280, 720)));

    assert!(packet_published.wait(Duration::from_secs(2)));
    let Some(packet) = buffer.consume_latest() else {
        thread.shutdown();
        panic!("expected a render packet from the simulation thread");
    };

    assert_eq!(packet.scene.camera.eye, Float3::new(0.0, 2.4, 7.5));
    assert_eq!(packet.scene.instances.len(), 2);
    assert_eq!(
        translation(&packet.scene.instances[0].transform),
        Float3::new(0.0, 1.0, 0.0)
    );
    assert_eq!(
        translation(&packet.scene.instances[1].transform),
        Float3::new(0.0, -1.0, 0.0)
    );

    assert!(frame_ready.wait(Duration::from_secs(2)));
    thread.shutdown();
}

/// joint_palette_override in a request takes precedence over the scene palette.
#[test]
fn joint_palette_override_appears_in_published_packet() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let packet_published = Arc::new(Signal::new());

    let packet_signal = packet_published.clone();
    let thread = SimulationThread::new(
        Arc::new(IdleRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        Arc::new(|_| {}),
        Arc::new(|_| {}),
        Arc::new(move || packet_signal.signal()),
        None,
    );

    let sentinel_entity = EntityID::new(99, 1);
    let mut palettes = std::collections::BTreeMap::new();
    palettes.insert(
        sentinel_entity,
        JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4]),
    );
    let override_map = JointPaletteMap::new(palettes);

    let request = SimulationFrameRequest::new(
        0,
        1.0 / 60.0,
        Vec::new(),
        RenderDrawableSize::new(64, 64),
        true,
        RenderSettings::new(),
        None,
        None,
        Some(override_map),
        None,
        false,
    );
    thread.submit(request);

    assert!(packet_published.wait(Duration::from_secs(2)));
    let Some(packet) = buffer.consume_latest() else {
        thread.shutdown();
        panic!("expected a render packet");
    };

    let palette = packet
        .joint_palette_map
        .palette(sentinel_entity)
        .expect("sentinel palette");
    assert!(!palette.matrices.is_empty());
    thread.shutdown();
}

/// An external scene frame publishes its own snapshot and canvas.
#[test]
fn external_scene_frame_owns_packet_metadata() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let packet_published = Arc::new(Signal::new());

    let packet_signal = packet_published.clone();
    let thread = SimulationThread::new(
        Arc::new(IdleRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        Arc::new(|_| {}),
        Arc::new(|_| {}),
        Arc::new(move || packet_signal.signal()),
        None,
    );

    let mut canvas = InGameCanvas::new();
    canvas.label("external", 4.0, 8.0);
    let snapshot = SceneRuntimeSnapshot::new(42, 9001);

    let request = SimulationFrameRequest::new(
        3,
        1.0 / 60.0,
        Vec::new(),
        RenderDrawableSize::new(64, 64),
        true,
        RenderSettings::new(),
        Some(diffuse_scene::rendering::render_scene::RenderScene::new(
            RenderCamera::fallback(),
            Vec::new(),
            Vec::new(),
            Default::default(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            None,
        )),
        Some(snapshot),
        None,
        Some(canvas),
        false,
    );
    thread.submit(request);

    assert!(packet_published.wait(Duration::from_secs(2)));
    let Some(packet) = buffer.consume_latest() else {
        thread.shutdown();
        panic!("expected a render packet");
    };
    assert_eq!(packet.scene_snapshot, snapshot);
    assert_eq!(packet.in_game_canvas.commands.len(), 1);
    thread.shutdown();
}

fn emitter_scene() -> (SceneRuntime, EntityID) {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let emitter_entity = scene.create_entity();
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.is_emitting = false;
    settings.emission.emission_rate = 0.0;
    settings.emission.max_particles = 4;
    settings.sub_emitters.legacy_trigger = ParticleSubEmitterTrigger::Death;
    settings.sub_emitters.legacy_burst_count = 1;
    settings.sub_emitters.legacy_lifetime = 2.0;
    settings.sub_emitters.legacy_start_velocity = Float3::ZERO;
    settings.sub_emitters.legacy_velocity_randomness = Float3::ZERO;
    settings.sub_emitters.legacy_start_size = 0.5;
    settings.sub_emitters.legacy_end_size = 0.5;
    settings.sub_emitters.legacy_start_color = Float4::new(1.0, 0.0, 0.0, 1.0);
    settings.sub_emitters.legacy_end_color = Float4::new(1.0, 0.0, 0.0, 1.0);
    settings.forces.gravity = Float3::ZERO;
    assert!(scene.set_component(ParticleEmitter::new(settings), emitter_entity));
    (scene, emitter_entity)
}

/// SimulationThread applies GPU particle events before publishing the next packet.
#[test]
fn simulation_thread_applies_gpu_particle_event_snapshots() {
    let (initial_scene, emitter_entity) = emitter_scene();
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let packet_published = Arc::new(Signal::new());
    let report_applied = Arc::new(Signal::new());
    let reports: Arc<Mutex<Vec<ParticleSimulationEventApplyReport>>> =
        Arc::new(Mutex::new(Vec::new()));

    let report_signal = report_applied.clone();
    let report_sink = reports.clone();
    let packet_signal = packet_published.clone();
    let thread = SimulationThread::new(
        Arc::new(IdleRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        Arc::new(|_| {}),
        Arc::new(move |report| {
            report_sink
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(report);
            report_signal.signal();
        }),
        Arc::new(move || packet_signal.signal()),
        Some(initial_scene),
    );

    let snapshot = GPUParticleSimulationEventSnapshot::new(
        0,
        Some(emitter_entity.raw_value()),
        2,
        3,
        2,
        vec![GPUParticleSimulationEventRecord::new(
            GPUParticleSimulationEventTrigger::Death,
            0,
            Float3::new(0.25, 0.0, 0.0),
            1.0,
            Float3::ZERO,
            1.0,
            0,
            0,
        )],
        4,
        1,
        0,
        2,
        1,
        4,
    );

    thread.submit_particle_simulation_event_snapshots(vec![snapshot]);
    let mut request = frame_request(1, RenderDrawableSize::new(64, 64));
    request.delta_time = 0.0;
    thread.submit(request);

    assert!(report_applied.wait(Duration::from_secs(2)));
    assert!(packet_published.wait(Duration::from_secs(2)));
    let report = reports
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)[0]
        .clone();
    assert_eq!(report.requested_emitter_count, 1);
    assert_eq!(report.applied_emitter_count, 1);
    assert_eq!(report.event_count, 1);
    assert_eq!(report.applied_event_count, 1);
    assert_eq!(report.total_readback_event_count, 3);
    assert_eq!(report.dropped_readback_event_count, 2);
    assert_eq!(report.death_event_count, 1);
    assert_eq!(report.sub_emitter_spawned_count, 1);
    assert_eq!(report.gpu_alive_particle_count, 4);
    assert_eq!(report.gpu_expired_particle_count, 1);
    assert_eq!(report.gpu_collision_event_count, 0);
    assert_eq!(report.gpu_spawned_particle_count, 2);
    assert_eq!(report.gpu_dropped_spawn_count, 1);
    assert_eq!(report.gpu_compacted_particle_count, 4);
    assert_eq!(report.dropped_spawn_count(), 1);

    let Some(packet) = buffer.consume_latest() else {
        thread.shutdown();
        panic!("expected a render packet from the simulation thread");
    };
    assert_eq!(packet.scene.particles.len(), 1);
    let particle = &packet.scene.particles[0];
    assert_eq!(particle.position, Float3::new(0.25, 0.0, 0.0));
    assert_eq!(particle.size, 0.5);
    assert_eq!(particle.color, Float4::new(1.0, 0.0, 0.0, 1.0));
    thread.shutdown();
}

/// Reports dropped GPU particle events when the readback has no records.
#[test]
fn simulation_thread_reports_dropped_gpu_events_without_records() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let report_applied = Arc::new(Signal::new());
    let reports: Arc<Mutex<Vec<ParticleSimulationEventApplyReport>>> =
        Arc::new(Mutex::new(Vec::new()));

    let report_signal = report_applied.clone();
    let report_sink = reports.clone();
    let thread = SimulationThread::new(
        Arc::new(IdleRuntime),
        buffer,
        Arc::new(|_, _| {}),
        Arc::new(|_| {}),
        Arc::new(move |report| {
            report_sink
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(report);
            report_signal.signal();
        }),
        Arc::new(|| {}),
        None,
    );

    let snapshot = GPUParticleSimulationEventSnapshot::new(
        0,
        Some(EntityID::new(7, 1).raw_value()),
        0,
        5,
        5,
        Vec::new(),
        7,
        3,
        2,
        4,
        6,
        7,
    );
    thread.submit_particle_simulation_event_snapshots(vec![snapshot]);

    assert!(report_applied.wait(Duration::from_secs(2)));
    let report = reports
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)[0]
        .clone();
    assert_eq!(report.requested_emitter_count, 0);
    assert_eq!(report.event_count, 0);
    assert_eq!(report.applied_event_count, 0);
    assert_eq!(report.total_readback_event_count, 5);
    assert_eq!(report.dropped_readback_event_count, 5);
    assert_eq!(report.gpu_alive_particle_count, 7);
    assert_eq!(report.gpu_expired_particle_count, 3);
    assert_eq!(report.gpu_collision_event_count, 2);
    assert_eq!(report.gpu_spawned_particle_count, 4);
    assert_eq!(report.gpu_dropped_spawn_count, 6);
    assert_eq!(report.gpu_compacted_particle_count, 7);
    assert_eq!(report.dropped_spawn_count(), 6);
    thread.shutdown();
}

/// SimulationThread forwards input events into the input phase and scene tick.
#[test]
fn simulation_thread_forwards_input_events() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let runtime = Arc::new(RecordingRuntime::new());
    let frame_ready = Arc::new(Signal::new());
    let packet_published = Arc::new(Signal::new());
    let phases: PhaseLog = Arc::new(Mutex::new(Vec::new()));
    let input_events = vec![
        InputEvent::WindowFocusGained,
        InputEvent::MouseMotion(MouseMotionEvent {
            x: 10.0,
            y: 20.0,
            delta_x: 1.0,
            delta_y: -2.0,
            ..MouseMotionEvent::default()
        }),
    ];

    let phase_sink = phases.clone();
    let frame_signal = frame_ready.clone();
    let packet_signal = packet_published.clone();
    let runtime_dyn: Arc<dyn EngineRuntime> = runtime.clone();
    let thread = SimulationThread::new(
        runtime_dyn,
        buffer.clone(),
        Arc::new(move |phase, context| {
            phase_sink
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push((phase, context));
        }),
        Arc::new(move |_| frame_signal.signal()),
        Arc::new(|_| {}),
        Arc::new(move || packet_signal.signal()),
        None,
    );

    let request = SimulationFrameRequest::new(
        7,
        1.0 / 30.0,
        input_events.clone(),
        RenderDrawableSize::new(1280, 720),
        true,
        RenderSettings::new(),
        None,
        None,
        None,
        None,
        false,
    );
    thread.submit(request);

    assert!(packet_published.wait(Duration::from_secs(2)));
    assert!(frame_ready.wait(Duration::from_secs(2)));

    let (delta_time, event_count) = runtime.last_input_call().expect("input tick");
    assert_eq!(delta_time, 1.0 / 30.0);
    assert_eq!(event_count, input_events.len());

    let Some(packet) = buffer.consume_latest() else {
        thread.shutdown();
        panic!("expected a render packet from the simulation thread");
    };
    assert!(packet.scene_snapshot.revision > 0);

    let phases = phases
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let recorded: Vec<EngineKernelPhase> = phases.iter().map(|(phase, _)| *phase).collect();
    assert_eq!(
        recorded,
        vec![
            EngineKernelPhase::Input,
            EngineKernelPhase::Simulation,
            EngineKernelPhase::RenderPrepare
        ]
    );
    assert!(phases.iter().all(|(_, context)| context.frame_index == 7));
    assert!(
        phases
            .iter()
            .all(|(_, context)| context.input_events.len() == input_events.len())
    );

    drop(phases);
    thread.shutdown();
}
