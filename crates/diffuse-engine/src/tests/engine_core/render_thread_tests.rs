//! Ported from `Engine/Tests/EngineCoreTests/RenderThreadTests.swift`.
//!
//! Two integration cases drive a real `RenderThread` through a GPU consumer and
//! keep the Swift suite's `COVE_RUN_GPU_SMOKE_TESTS=1` gate.

use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::engine_core::EngineRuntime;
use crate::latest_value_buffer::LatestValueBuffer;
use crate::render_thread::{RenderThread, RenderThreadReport};
use cove_graphics::rhi::{Device, DeviceConfig, Texture};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::engine_kernel::{EngineKernelPhase, EngineKernelPhaseContext};
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_kernel::input_event::InputEvent;
use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_packet::RenderPacketConsumer;
use diffuse_render::core::render_stats::{
    GPUParticleSimulationEventRecord, GPUParticleSimulationEventSnapshot,
    GPUParticleSimulationEventTrigger, RenderFrameStats,
};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::passes::native_grid_renderer::NativeGridRenderer;
use diffuse_render::surface::viewport_surface::{ViewportSamplingRegion, ViewportSurfaceState};
use diffuse_render::{RenderDrawableSize, RenderPacket, RenderPassKind, RenderSettings};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderEnvironment, RenderInstance, RenderMaterial, RenderScene,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

fn gpu_smoke_tests_enabled() -> bool {
    std::env::var("COVE_RUN_GPU_SMOKE_TESTS").as_deref() == Ok("1")
}

fn make_packet(frame_index: i64) -> RenderPacket {
    RenderPacket::new(
        frame_index,
        1.0 / 60.0,
        RenderDrawableSize::new(1280, 720),
        RenderScene::new(
            RenderCamera::new(Float3::new(0.0, 2.0, 5.0), Float3::ZERO),
            vec![RenderInstance::from_mesh_index(
                0,
                MATRIX_IDENTITY_FLOAT4X4,
                Float3::splat(1.0),
                RenderMaterial::fallback(),
                None,
            )],
            Vec::new(),
            RenderEnvironment::default(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            None,
        ),
        SceneRuntimeSnapshot::new(1, frame_index as u64),
        RenderSettings::new(),
        frame_index as f64 / 60.0,
        JointPaletteMap::default(),
        InGameCanvas::new(),
    )
}

struct NoopRuntime;
impl EngineRuntime for NoopRuntime {
    fn initialize(&self) {}
    fn tick_input(&self, _delta_time: f64, _input_events: &[InputEvent]) {}
    fn tick_simulation(&self, _delta_time: f64) {}
    fn tick_render_prepare(&self, _delta_time: f64) {}
    fn tick_render_submit(&self, _delta_time: f64) {}
    fn shutdown(&self) {}
}

/// Hands a consumer to the render thread while keeping shared access for the
/// assertions the Swift suite makes after `shutdown()`.
struct SharedConsumer<T> {
    inner: Arc<Mutex<T>>,
}

impl<T> SharedConsumer<T> {
    fn new(inner: Arc<Mutex<T>>) -> Self {
        SharedConsumer { inner }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, T> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl<T: RenderPacketConsumer> RenderPacketConsumer for SharedConsumer<T> {
    fn initialize(&mut self) {
        self.lock().initialize();
    }

    fn render(&mut self, packet: &RenderPacket) {
        self.lock().render(packet);
    }

    fn current_frame_stats(&self) -> RenderFrameStats {
        self.lock().current_frame_stats()
    }

    fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        self.lock().current_viewport_surface_state()
    }

    fn drain_gpu_particle_simulation_event_snapshots(
        &mut self,
        max_snapshots: usize,
    ) -> Result<Vec<GPUParticleSimulationEventSnapshot>, cove_graphics::rhi::RhiError> {
        self.lock()
            .drain_gpu_particle_simulation_event_snapshots(max_snapshots)
    }
}

type ReportSink = Arc<dyn Fn(RenderThreadReport) + Send + Sync>;

fn report_recorder() -> (Arc<Mutex<Vec<RenderThreadReport>>>, ReportSink) {
    let reports = Arc::new(Mutex::new(Vec::new()));
    let sink = reports.clone();
    (
        reports,
        Arc::new(move |report: RenderThreadReport| {
            sink.lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(report);
        }),
    )
}

fn render_signal_recorder() -> (std::sync::mpsc::Receiver<RenderThreadReport>, ReportSink) {
    let (sender, receiver) = channel::<RenderThreadReport>();
    let sender: Arc<Mutex<Sender<RenderThreadReport>>> = Arc::new(Mutex::new(sender));
    (
        receiver,
        Arc::new(move |report: RenderThreadReport| {
            let _ = sender
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .send(report);
        }),
    )
}

fn empty_surface_state() -> ViewportSurfaceState {
    let zero = RenderDrawableSize::new(0, 0);
    ViewportSurfaceState::with_region(0, None, ViewportSamplingRegion::new(zero, zero))
}

/// RenderThread consumes real packets through the NativeRHI grid renderer.
#[test]
fn native_grid_render_packet_integration() {
    if !gpu_smoke_tests_enabled() {
        return;
    }

    let device = Arc::new(
        Device::make(DeviceConfig {
            enable_validation: false,
            ..DeviceConfig::default()
        })
        .expect("device"),
    );
    let consumer = Arc::new(Mutex::new(
        NativeGridRenderer::new(&device, None).expect("grid renderer"),
    ));
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let (rendered, on_frame_rendered) = render_signal_recorder();
    let thread = RenderThread::new(
        Arc::new(NoopRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        Box::new(SharedConsumer::new(consumer.clone())),
        on_frame_rendered,
    );
    let mut packet = make_packet(17);
    packet.drawable_size = RenderDrawableSize::new(128, 96);
    packet.scene.instances = Vec::new();
    packet.render_settings.viewport.grid_enabled = true;
    buffer.publish(packet.clone());
    thread.request_render();
    let report = rendered
        .recv_timeout(Duration::from_secs(5))
        .expect("grid frame rendered");
    thread.shutdown();
    device.wait_until_idle().expect("idle");

    let consumer = consumer
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert!(consumer.last_error().is_none());
    assert_eq!(consumer.current_frame_stats().frame_index, 17);
    assert_eq!(
        consumer
            .current_frame_stats()
            .pass_draw_call_counts
            .get(&RenderPassKind::EditorGrid)
            .copied(),
        Some(1)
    );
    let color: Option<Texture> = consumer.color_texture();
    assert!(color.is_some());
    let surface = consumer.current_viewport_surface_state();
    assert!(surface.is_valid());
    assert_eq!(surface.region.size, packet.drawable_size);

    let reported = report.viewport_surface_state;
    assert!(reported == surface);
    assert!(Arc::ptr_eq(
        reported.image.as_ref().expect("reported image"),
        surface.image.as_ref().expect("surface image")
    ));
    let resource = surface
        .image
        .as_ref()
        .expect("surface image")
        .resource
        .clone();
    assert_eq!(Some(resource.texture()), color);
}

/// RenderThread consumes indexed scene packets through NativeRenderer.
#[test]
fn native_scene_render_packet_integration() {
    if !gpu_smoke_tests_enabled() {
        return;
    }

    let device = Arc::new(
        Device::make(DeviceConfig {
            enable_validation: false,
            ..DeviceConfig::default()
        })
        .expect("device"),
    );
    let consumer = Arc::new(Mutex::new(
        NativeRenderer::new(
            &device,
            None,
            AssetRegistry::shared(),
            None,
            &RenderSettings::new(),
            &[],
        )
        .expect("renderer"),
    ));
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let (rendered, on_frame_rendered) = render_signal_recorder();
    let thread = RenderThread::new(
        Arc::new(NoopRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        Box::new(SharedConsumer::new(consumer.clone())),
        on_frame_rendered,
    );
    let mut packet = make_packet(21);
    packet.drawable_size = RenderDrawableSize::new(128, 96);
    packet.render_settings.shading.pbr = false;
    packet.render_settings.shading.depth_prepass = true;
    packet.render_settings.shading.debug_view_mode = diffuse_render::DebugViewMode::Unlit;
    packet.render_settings.viewport.grid_enabled = true;
    buffer.publish(packet);
    thread.request_render();
    rendered
        .recv_timeout(Duration::from_secs(5))
        .expect("scene frame rendered");
    thread.shutdown();
    device.wait_until_idle().expect("idle");

    let consumer = consumer
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert!(consumer.last_error().is_none());
    let stats = consumer.current_frame_stats();
    assert_eq!(stats.frame_index, 21);
    assert_eq!(
        stats
            .pass_draw_call_counts
            .get(&RenderPassKind::BasePass)
            .copied(),
        Some(1)
    );
    assert_eq!(
        stats
            .pass_draw_call_counts
            .get(&RenderPassKind::DepthPrepass)
            .copied(),
        Some(1)
    );
    assert_eq!(
        stats
            .pass_draw_call_counts
            .get(&RenderPassKind::EditorGrid)
            .copied(),
        Some(1)
    );
    assert_eq!(stats.submitted_mesh_triangle_count, 12);
}

/// LatestValueBuffer returns the latest published payload.
#[test]
fn packet_buffer_returns_latest_payload() {
    let buffer: LatestValueBuffer<i32> = LatestValueBuffer::with_default_capacity();
    buffer.publish(1);
    buffer.publish(2);
    buffer.publish(3);

    assert_eq!(buffer.consume_latest(), Some(3));
    assert_eq!(buffer.consume_latest(), None);
}

struct Gate {
    state: Mutex<(bool, bool)>,
    condvar: Condvar,
}

impl Gate {
    fn new() -> Self {
        Gate {
            state: Mutex::new((false, false)),
            condvar: Condvar::new(),
        }
    }

    fn wait_started(&self, timeout: Duration) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let deadline = std::time::Instant::now() + timeout;
        while !state.0 {
            let now = std::time::Instant::now();
            assert!(now < deadline, "first render never started");
            let (guard, _) = self
                .condvar
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state = guard;
        }
    }

    fn signal_started(&self) {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .0 = true;
        self.condvar.notify_all();
    }

    fn wait_release(&self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        while !state.1 {
            state = self
                .condvar
                .wait(state)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }

    fn release(&self) {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .1 = true;
        self.condvar.notify_all();
    }
}

/// Blocks the first render so the test can queue a second request meanwhile.
struct TestConsumer {
    gate: Arc<Gate>,
    render_count: i64,
}

impl RenderPacketConsumer for TestConsumer {
    fn initialize(&mut self) {}

    fn render(&mut self, _packet: &RenderPacket) {
        self.render_count += 1;
        self.gate.signal_started();
        if self.render_count == 1 {
            self.gate.wait_release();
        }
    }

    fn current_frame_stats(&self) -> RenderFrameStats {
        RenderFrameStats::default()
    }

    fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        empty_surface_state()
    }
}

/// RenderThread drains a follow-up render request after the current pass.
#[test]
fn render_thread_drains_follow_up_request() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let gate = Arc::new(Gate::new());
    let consumer = Box::new(TestConsumer {
        gate: gate.clone(),
        render_count: 0,
    });
    let (reports, on_frame_rendered) = report_recorder();

    let thread = RenderThread::new(
        Arc::new(NoopRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        consumer,
        on_frame_rendered,
    );

    buffer.publish(make_packet(0));
    thread.request_render();
    gate.wait_started(Duration::from_secs(2));

    buffer.publish(make_packet(1));
    thread.request_render();
    gate.release();

    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while reports
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .len()
        < 2
    {
        assert!(
            std::time::Instant::now() < deadline,
            "follow-up never rendered"
        );
        std::thread::sleep(Duration::from_millis(5));
    }

    let frames: Vec<i64> = reports
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .map(|report| report.frame_index)
        .collect();
    assert_eq!(frames, vec![0, 1]);

    thread.shutdown();
}

struct FastConsumer;

impl RenderPacketConsumer for FastConsumer {
    fn initialize(&mut self) {}
    fn render(&mut self, _packet: &RenderPacket) {}
    fn current_frame_stats(&self) -> RenderFrameStats {
        RenderFrameStats::default()
    }
    fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        empty_surface_state()
    }
}

/// RenderThread emits the render submit kernel phase before rendering.
#[test]
fn render_thread_emits_render_submit_phase() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let phases: Arc<Mutex<Vec<(EngineKernelPhase, EngineKernelPhaseContext)>>> =
        Arc::new(Mutex::new(Vec::new()));
    let recorder = phases.clone();
    let (rendered, on_frame_rendered) = render_signal_recorder();

    let thread = RenderThread::new(
        Arc::new(NoopRuntime),
        buffer.clone(),
        Arc::new(move |phase, context| {
            recorder
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push((phase, context));
        }),
        Box::new(FastConsumer),
        on_frame_rendered,
    );

    buffer.publish(make_packet(9));
    thread.request_render();

    rendered
        .recv_timeout(Duration::from_secs(2))
        .expect("frame rendered");
    let phases = phases
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert_eq!(phases.len(), 1);
    let (phase, context) = &phases[0];
    assert_eq!(*phase, EngineKernelPhase::RenderSubmit);
    assert_eq!(context.frame_index, 9);
    assert_eq!(context.delta_time, 1.0 / 60.0);
    assert!(context.input_events.is_empty());

    drop(phases);
    thread.shutdown();
}

/// Returns queued snapshots and counts the drains.
struct SnapshotConsumer {
    snapshots: Vec<GPUParticleSimulationEventSnapshot>,
    drained: usize,
}

impl RenderPacketConsumer for SnapshotConsumer {
    fn initialize(&mut self) {}

    fn render(&mut self, _packet: &RenderPacket) {}

    fn current_frame_stats(&self) -> RenderFrameStats {
        RenderFrameStats::default()
    }

    fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        empty_surface_state()
    }

    fn drain_gpu_particle_simulation_event_snapshots(
        &mut self,
        max_snapshots: usize,
    ) -> Result<Vec<GPUParticleSimulationEventSnapshot>, cove_graphics::rhi::RhiError> {
        self.drained += 1;
        let count = max_snapshots.min(self.snapshots.len());
        Ok(self.snapshots.drain(..count).collect())
    }
}

/// RenderThread reports drained GPU particle simulation events.
#[test]
fn render_thread_reports_drained_gpu_particle_simulation_events() {
    let buffer = Arc::new(LatestValueBuffer::with_default_capacity());
    let snapshot = GPUParticleSimulationEventSnapshot::new(
        0,
        Some(EntityID::new(2, 1).raw_value()),
        4,
        1,
        0,
        vec![GPUParticleSimulationEventRecord::new(
            GPUParticleSimulationEventTrigger::Death,
            0,
            Float3::ZERO,
            1.0,
            Float3::ZERO,
            1.0,
            0,
            0,
        )],
        0,
        0,
        0,
        0,
        0,
        0,
    );
    let consumer = Box::new(SnapshotConsumer {
        snapshots: vec![snapshot.clone()],
        drained: 0,
    });
    let (reports, on_frame_rendered) = report_recorder();

    let thread = RenderThread::new(
        Arc::new(NoopRuntime),
        buffer.clone(),
        Arc::new(|_, _| {}),
        consumer,
        on_frame_rendered,
    );

    buffer.publish(make_packet(3));
    thread.request_render();

    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while reports
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_empty()
    {
        assert!(std::time::Instant::now() < deadline, "frame never rendered");
        std::thread::sleep(Duration::from_millis(5));
    }
    let reports = reports
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert_eq!(
        reports[0].particle_simulation_event_snapshots,
        vec![snapshot]
    );

    drop(reports);
    thread.shutdown();
}
