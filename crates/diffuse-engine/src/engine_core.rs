//! Translation of Engine/Sources/EngineCore/EngineCore.swift.
//!
//! `EngineHost` owns one runtime, the simulation and render threads, and the
//! latest-wins packet handoff between them. The host stays `&self`-driven like
//! Swift's class: every mutable piece sits behind a `LockedState`.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};

use cove_graphics::rhi::{Device, ResourcePreparationProgress, RhiResult};
use cove_logging::{Level, LogEvent, LogSystem};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::engine_kernel::{
    EngineKernel, EngineKernelFrameReport, EngineKernelPhase, EngineKernelPhaseContext,
};
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_kernel::input_event::InputEvent;
use diffuse_render::RenderDrawableSize;
use diffuse_render::core::frame::render_packet::{
    RenderPacket, RenderPacketConsumer, RenderSurfaceDescriptor,
};
use diffuse_render::core::render_settings::RenderSettings;
use diffuse_render::core::render_stats::{GPUParticleSimulationEventSnapshot, RenderFrameStats};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::in_game_ui_providing::InGameUIProviding;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use diffuse_scene::rendering::render_scene::RenderScene;
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use crate::latest_value_buffer::LatestValueBuffer;
use crate::locked_state::LockedState;
use crate::render_thread::{RenderThread, RenderThreadReport};
use crate::simulation_thread::{SimulationFrameReport, SimulationFrameRequest, SimulationThread};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TickPhase {
    Input,
    Simulation,
    RenderPrepare,
    RenderSubmit,
}

impl TickPhase {
    pub const ALL: [TickPhase; 4] = [
        TickPhase::Input,
        TickPhase::Simulation,
        TickPhase::RenderPrepare,
        TickPhase::RenderSubmit,
    ];
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PhaseTimings {
    pub input_seconds: f64,
    pub simulation_seconds: f64,
    pub render_prepare_seconds: f64,
    pub render_submit_seconds: f64,
}

/// The engine-side frame callbacks. Swift's protocol has non-mutating methods,
/// so the runtime is shared rather than moved into the host.
pub trait EngineRuntime: Send + Sync {
    fn initialize(&self);
    fn tick_input(&self, delta_time: f64, input_events: &[InputEvent]);
    fn tick_simulation(&self, delta_time: f64);
    fn tick_render_prepare(&self, delta_time: f64);
    fn tick_render_submit(&self, delta_time: f64);
    fn shutdown(&self);
}

#[derive(Default)]
struct FrameTimingLedger {
    partial: BTreeMap<i64, PhaseTimings>,
    last_completed: PhaseTimings,
}

impl FrameTimingLedger {
    fn begin_frame(&mut self, frame_index: i64) {
        self.partial.insert(frame_index, PhaseTimings::default());
    }

    fn update_simulation(&mut self, report: &SimulationFrameReport) {
        let mut timings = self
            .partial
            .get(&report.frame_index)
            .copied()
            .unwrap_or_default();
        timings.input_seconds = report.input_seconds;
        timings.simulation_seconds = report.simulation_seconds;
        timings.render_prepare_seconds = report.render_prepare_seconds;
        self.partial.insert(report.frame_index, timings);
        if !report.render_requested {
            self.last_completed = timings;
            self.partial.remove(&report.frame_index);
        }
        self.trim(report.frame_index - 6);
    }

    fn complete_render(&mut self, report: &RenderThreadReport) {
        let mut timings = self
            .partial
            .get(&report.frame_index)
            .copied()
            .unwrap_or_default();
        timings.render_submit_seconds = report.render_submit_seconds;
        self.last_completed = timings;
        self.partial.remove(&report.frame_index);
        self.trim(report.frame_index - 6);
    }

    fn trim(&mut self, floor: i64) {
        self.partial.retain(|frame_index, _| *frame_index >= floor);
    }
}

type ParticleFeedbackHandler = Arc<dyn Fn(&[GPUParticleSimulationEventSnapshot]) + Send + Sync>;
type RenderCompletionHandler = Arc<dyn Fn(EngineRenderCompletion) + Send + Sync>;

struct EngineHostState {
    started: bool,
    next_frame_index: i64,
    current_input_events: Vec<InputEvent>,
    render_settings: RenderSettings,
    render_stats: RenderFrameStats,
    particle_simulation_event_apply_report: ParticleSimulationEventApplyReport,
    viewport_surface_state: ViewportSurfaceState,
    render_completion_handler: Option<RenderCompletionHandler>,
    external_particle_feedback_handlers: BTreeMap<i64, ParticleFeedbackHandler>,
}

impl Default for EngineHostState {
    fn default() -> Self {
        EngineHostState {
            started: false,
            next_frame_index: 0,
            current_input_events: Vec::new(),
            render_settings: RenderSettings::default(),
            render_stats: RenderFrameStats::default(),
            particle_simulation_event_apply_report: ParticleSimulationEventApplyReport::empty(),
            viewport_surface_state: ViewportSurfaceState::default(),
            render_completion_handler: None,
            external_particle_feedback_handlers: BTreeMap::new(),
        }
    }
}

#[derive(Clone)]
pub struct EngineRenderCompletion {
    pub frame_index: i64,
    pub delta_time: f64,
    pub render_submit_seconds: f64,
    pub stats: RenderFrameStats,
    pub viewport_surface_state: ViewportSurfaceState,
}

impl EngineRenderCompletion {
    pub fn new(
        frame_index: i64,
        delta_time: f64,
        render_submit_seconds: f64,
        stats: RenderFrameStats,
        viewport_surface_state: ViewportSurfaceState,
    ) -> Self {
        EngineRenderCompletion {
            frame_index,
            delta_time,
            render_submit_seconds,
            stats,
            viewport_surface_state,
        }
    }
}

#[derive(Default)]
struct HostThreads {
    packet_buffer: Option<Arc<LatestValueBuffer<RenderPacket>>>,
    simulation_thread: Option<Arc<SimulationThread>>,
    render_thread: Option<Arc<RenderThread>>,
}

/// The engine host: one runtime plus the two worker threads.
pub struct EngineHost {
    runtime: Arc<dyn EngineRuntime>,
    kernel: Arc<LockedState<EngineKernelCoordinator>>,
    state: Arc<LockedState<EngineHostState>>,
    timings: Arc<LockedState<FrameTimingLedger>>,
    in_game_ui: Mutex<Option<Box<dyn InGameUIProviding>>>,
    /// Shared rendering device; `None` runs simulation without a GPU.
    pub render_device: Option<Arc<Device>>,
    threads: Mutex<HostThreads>,
}

impl EngineHost {
    pub fn new(
        runtime: Arc<dyn EngineRuntime>,
        render_device: Option<Arc<Device>>,
        in_game_ui: Option<Box<dyn InGameUIProviding>>,
    ) -> Self {
        EngineHost {
            runtime,
            kernel: Arc::new(LockedState::new(EngineKernelCoordinator::new())),
            state: Arc::new(LockedState::new(EngineHostState::default())),
            timings: Arc::new(LockedState::new(FrameTimingLedger::default())),
            in_game_ui: Mutex::new(in_game_ui),
            render_device,
            threads: Mutex::new(HostThreads::default()),
        }
    }

    fn threads(&self) -> std::sync::MutexGuard<'_, HostThreads> {
        self.threads
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn take_in_game_ui(&self) -> Option<Box<dyn InGameUIProviding>> {
        self.in_game_ui
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
    }

    pub fn last_timings(&self) -> PhaseTimings {
        self.timings.with_lock(|timings| timings.last_completed)
    }

    pub fn current_input_events(&self) -> Vec<InputEvent> {
        self.state
            .with_lock(|state| state.current_input_events.clone())
    }

    pub fn is_started(&self) -> bool {
        self.state.with_lock(|state| state.started)
    }

    /// Returns an owned renderer without starting simulation or a render thread.
    /// The host publishes it after checking its loading task is still current.
    pub fn prepare_renderer(
        &self,
        render_surface: Option<RenderSurfaceDescriptor>,
        enable_viewport_surface: bool,
        initial_settings: &RenderSettings,
        on_progress: impl Fn(ResourcePreparationProgress) + Send + Sync + 'static,
    ) -> RhiResult<Option<NativeRenderer>> {
        let Some(device) = self.render_device.clone() else {
            return Ok(None);
        };
        if render_surface.is_none() && !enable_viewport_surface {
            return Ok(None);
        }
        let in_game_ui = self.take_in_game_ui();
        NativeRenderer::prepared(
            &device,
            render_surface,
            AssetRegistry::shared(),
            in_game_ui,
            initial_settings,
            &[],
            on_progress,
        )
        .map(Some)
    }

    /// A supplied consumer receives the normal `RenderPacket` stream, allowing
    /// isolated native passes to run without changing the default renderer.
    pub fn start(
        &self,
        render_surface: Option<RenderSurfaceDescriptor>,
        enable_viewport_surface: bool,
        render_consumer: Option<Box<dyn RenderPacketConsumer>>,
    ) {
        let should_start = self.state.with_lock(|state| {
            if state.started {
                return false;
            }
            state.started = true;
            true
        });
        if !should_start {
            return;
        }

        self.runtime.initialize();
        self.kernel.with_lock(|kernel| kernel.boot());

        let packet_buffer = Arc::new(LatestValueBuffer::<RenderPacket>::with_default_capacity());

        let consumer: Option<Box<dyn RenderPacketConsumer>> = match render_consumer {
            Some(consumer) => Some(consumer),
            None => match self.render_device.clone() {
                Some(device) if render_surface.is_some() || enable_viewport_surface => {
                    let in_game_ui = self.take_in_game_ui();
                    match NativeRenderer::new(
                        &device,
                        render_surface,
                        AssetRegistry::shared(),
                        in_game_ui,
                        &RenderSettings::default(),
                        &[],
                    ) {
                        Ok(renderer) => Some(Box::new(renderer)),
                        Err(error) => {
                            LogSystem::logger("com.cove.engine.host").log(&LogEvent::new(
                                Level::Error,
                                format!("Renderer initialization failed: {error}"),
                            ));
                            None
                        }
                    }
                }
                _ => None,
            },
        };

        let kernel = self.kernel.clone();
        let on_kernel_phase: Arc<
            dyn Fn(EngineKernelPhase, EngineKernelPhaseContext) + Send + Sync,
        > = Arc::new(move |phase, context| {
            kernel.with_lock(|kernel| {
                let _ = kernel.tick(phase, context);
            });
        });

        let simulation_slot: Arc<OnceLock<Arc<SimulationThread>>> = Arc::new(OnceLock::new());
        let render_thread = consumer.map(|consumer| {
            let state = self.state.clone();
            let timings = self.timings.clone();
            let slot = simulation_slot.clone();
            let on_frame_rendered: Arc<dyn Fn(RenderThreadReport) + Send + Sync> =
                Arc::new(move |report| {
                    handle_rendered_frame(&state, &timings, &slot, report);
                });
            Arc::new(RenderThread::new(
                self.runtime.clone(),
                packet_buffer.clone(),
                on_kernel_phase.clone(),
                consumer,
                on_frame_rendered,
            ))
        });

        let timings = self.timings.clone();
        let state = self.state.clone();
        let packet_publisher = render_thread.clone();
        let simulation_thread = Arc::new(SimulationThread::new(
            self.runtime.clone(),
            packet_buffer.clone(),
            on_kernel_phase,
            Arc::new(move |report: SimulationFrameReport| {
                timings.with_lock(|ledger| ledger.update_simulation(&report));
            }),
            Arc::new(move |report: ParticleSimulationEventApplyReport| {
                state.with_lock(|state| {
                    state.particle_simulation_event_apply_report = report;
                });
            }),
            Arc::new(move || {
                if let Some(render_thread) = packet_publisher.as_ref() {
                    render_thread.request_render();
                }
            }),
            None,
        ));
        let _ = simulation_slot.set(simulation_thread.clone());

        let mut threads = self.threads();
        threads.packet_buffer = Some(packet_buffer);
        threads.render_thread = render_thread;
        threads.simulation_thread = Some(simulation_thread);
    }

    /// `start(renderSurface:enableViewportSurface:renderConsumer:)` defaults.
    pub fn start_default(&self) {
        self.start(None, false, None);
    }

    #[allow(clippy::too_many_arguments)]
    pub fn tick(
        &self,
        delta_time: f64,
        input_events: Vec<InputEvent>,
        drawable_size: RenderDrawableSize,
        should_render: bool,
        render_scene_override: Option<RenderScene>,
        scene_snapshot_override: Option<SceneRuntimeSnapshot>,
        joint_palette_override: Option<JointPaletteMap>,
        in_game_canvas_override: Option<InGameCanvas>,
        particle_feedback_handler: Option<ParticleFeedbackHandler>,
        mipmapped_viewport_output: bool,
    ) {
        let threads = self.threads();
        let simulation_thread = threads.simulation_thread.clone();
        let will_render_possible = threads.render_thread.is_some();
        drop(threads);

        let request = self
            .state
            .with_lock(|state| -> Option<SimulationFrameRequest> {
                if !state.started {
                    return None;
                }
                let frame_index = state.next_frame_index;
                state.next_frame_index += 1;
                state.current_input_events = input_events.clone();
                let will_render = should_render && will_render_possible;
                if will_render && let Some(handler) = particle_feedback_handler {
                    state
                        .external_particle_feedback_handlers
                        .insert(frame_index, handler);
                }
                state
                    .external_particle_feedback_handlers
                    .retain(|frame, _| *frame >= frame_index - 8);
                Some(SimulationFrameRequest::new(
                    frame_index,
                    delta_time,
                    input_events,
                    drawable_size,
                    will_render,
                    state.render_settings,
                    render_scene_override,
                    scene_snapshot_override,
                    joint_palette_override,
                    in_game_canvas_override,
                    mipmapped_viewport_output,
                ))
            });
        let Some(request) = request else { return };
        let Some(simulation_thread) = simulation_thread else {
            return;
        };

        let frame_index = request.frame_index;
        self.timings
            .with_lock(|ledger| ledger.begin_frame(frame_index));
        simulation_thread.submit(request);
    }

    /// `tick(deltaTime:)` with every other argument at its Swift default.
    pub fn tick_simple(&self, delta_time: f64) {
        self.tick(
            delta_time,
            Vec::new(),
            RenderDrawableSize::default(),
            true,
            None,
            None,
            None,
            None,
            None,
            false,
        );
    }

    pub fn queue_render_settings(&self, settings: RenderSettings) {
        self.state
            .with_lock(|state| state.render_settings = settings);
    }

    pub fn current_render_stats(&self) -> RenderFrameStats {
        self.state.with_lock(|state| state.render_stats.clone())
    }

    pub fn current_particle_simulation_event_apply_report(
        &self,
    ) -> ParticleSimulationEventApplyReport {
        self.state
            .with_lock(|state| state.particle_simulation_event_apply_report.clone())
    }

    pub fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        self.state
            .with_lock(|state| state.viewport_surface_state.clone())
    }

    pub fn set_render_completion_handler(&self, handler: Option<RenderCompletionHandler>) {
        self.state
            .with_lock(|state| state.render_completion_handler = handler);
    }

    pub fn shutdown(&self) {
        let should_shutdown = self.state.with_lock(|state| {
            if !state.started {
                return false;
            }
            state.started = false;
            state.render_completion_handler = None;
            true
        });
        if !should_shutdown {
            return;
        }

        let mut threads = self.threads();
        if let Some(simulation_thread) = threads.simulation_thread.take() {
            simulation_thread.shutdown();
        }
        if let Some(render_thread) = threads.render_thread.take() {
            render_thread.shutdown();
        }
        threads.packet_buffer = None;
        drop(threads);

        self.kernel.with_lock(|kernel| kernel.shutdown());
        self.runtime.shutdown();
    }
}

impl Drop for EngineHost {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn handle_rendered_frame(
    state: &LockedState<EngineHostState>,
    timings: &LockedState<FrameTimingLedger>,
    simulation_thread: &OnceLock<Arc<SimulationThread>>,
    report: RenderThreadReport,
) {
    let completion = EngineRenderCompletion::new(
        report.frame_index,
        report.delta_time,
        report.render_submit_seconds,
        report.stats.clone(),
        report.viewport_surface_state.clone(),
    );
    let (completion_handler, particle_feedback_handler) = state.with_lock(|state| {
        state.render_stats = report.stats.clone();
        state.viewport_surface_state = report.viewport_surface_state.clone();
        (
            state.render_completion_handler.clone(),
            state
                .external_particle_feedback_handlers
                .remove(&report.frame_index),
        )
    });
    if let Some(particle_feedback_handler) = particle_feedback_handler {
        particle_feedback_handler(&report.particle_simulation_event_snapshots);
    } else if let Some(simulation_thread) = simulation_thread.get() {
        simulation_thread.submit_particle_simulation_event_snapshots(
            report.particle_simulation_event_snapshots.clone(),
        );
    }
    timings.with_lock(|ledger| ledger.complete_render(&report));
    if let Some(completion_handler) = completion_handler {
        completion_handler(completion);
    }
}

pub struct EngineKernelCoordinator {
    last_frame_index: u64,
}

impl Default for EngineKernelCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl EngineKernelCoordinator {
    pub fn new() -> Self {
        EngineKernelCoordinator {
            last_frame_index: 0,
        }
    }
}

impl EngineKernel for EngineKernelCoordinator {
    fn boot(&mut self) {}

    fn tick(
        &mut self,
        phase: EngineKernelPhase,
        context: EngineKernelPhaseContext,
    ) -> EngineKernelFrameReport {
        self.last_frame_index = self.last_frame_index.max(context.frame_index);
        EngineKernelFrameReport::new(
            context.frame_index,
            phase,
            EngineKernelPhase::ALL.len(),
            context.input_events.len(),
        )
    }

    fn shutdown(&mut self) {}
}
