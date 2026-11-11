//! Translation of Engine/Sources/EngineCore/SimulationThread.swift.
//!
//! One simulation worker per host. Requests arrive on a channel, so the caller
//! never blocks on scene work. The worker owns the scene, script runtime, asset
//! pipeline and audio engine.

use std::collections::BTreeMap;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

use diffuse_assets::asset_pipeline::AssetPipeline;
use diffuse_audio::audio_engine::AudioEngine;
use diffuse_kernel::engine_kernel::{EngineKernelPhase, EngineKernelPhaseContext};
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_kernel::input_event::InputEvent;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_render::RenderDrawableSize;
use diffuse_render::RenderPacket;
use diffuse_render::core::particles::gpu_particle_simulation_event_bridge::GPUParticleSimulationEventSnapshotBridge;
use diffuse_render::core::render_settings::RenderSettings;
use diffuse_render::core::render_stats::GPUParticleSimulationEventSnapshot;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::particles::particle_events::ParticleEvent;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use diffuse_scene::rendering::render_scene::RenderScene;
use diffuse_scene::scene_runtime::{SceneRuntime, SceneRuntimeSnapshot};
use diffuse_scene::scripting::SharedRuntimeScriptDriver;
use diffuse_script::core::script_runtime::ScriptRuntime;

use crate::engine_core::EngineRuntime;
use crate::latest_value_buffer::LatestValueBuffer;

#[derive(Clone)]
pub struct SimulationFrameRequest {
    pub frame_index: i64,
    pub delta_time: f64,
    pub input_events: Vec<InputEvent>,
    pub drawable_size: RenderDrawableSize,
    pub should_render: bool,
    pub mipmapped_viewport_output: bool,
    pub render_settings: RenderSettings,
    pub render_scene_override: Option<RenderScene>,
    pub scene_snapshot_override: Option<SceneRuntimeSnapshot>,
    pub joint_palette_override: Option<JointPaletteMap>,
    pub in_game_canvas_override: Option<InGameCanvas>,
}

impl SimulationFrameRequest {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        frame_index: i64,
        delta_time: f64,
        input_events: Vec<InputEvent>,
        drawable_size: RenderDrawableSize,
        should_render: bool,
        render_settings: RenderSettings,
        render_scene_override: Option<RenderScene>,
        scene_snapshot_override: Option<SceneRuntimeSnapshot>,
        joint_palette_override: Option<JointPaletteMap>,
        in_game_canvas_override: Option<InGameCanvas>,
        mipmapped_viewport_output: bool,
    ) -> Self {
        SimulationFrameRequest {
            frame_index,
            delta_time,
            input_events,
            drawable_size,
            should_render,
            mipmapped_viewport_output,
            render_settings,
            render_scene_override,
            scene_snapshot_override,
            joint_palette_override,
            in_game_canvas_override,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SimulationFrameReport {
    pub frame_index: i64,
    pub delta_time: f64,
    pub input_seconds: f64,
    pub simulation_seconds: f64,
    pub render_prepare_seconds: f64,
    pub render_requested: bool,
}

impl SimulationFrameReport {
    pub fn new(
        frame_index: i64,
        delta_time: f64,
        input_seconds: f64,
        simulation_seconds: f64,
        render_prepare_seconds: f64,
        render_requested: bool,
    ) -> Self {
        SimulationFrameReport {
            frame_index,
            delta_time,
            input_seconds,
            simulation_seconds,
            render_prepare_seconds,
            render_requested,
        }
    }
}

enum SimulationCommand {
    Frame(Box<SimulationFrameRequest>),
    ParticleSnapshots(Vec<GPUParticleSimulationEventSnapshot>),
    Shutdown,
}

struct SimulationState {
    scene_runtime: SceneRuntime,
    asset_pipeline: AssetPipeline,
    audio_engine: AudioEngine,
    simulation_time_seconds: f64,
}

pub struct SimulationThread {
    sender: Sender<SimulationCommand>,
    handle: Mutex<Option<JoinHandle<()>>>,
}

impl SimulationThread {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        runtime: Arc<dyn EngineRuntime>,
        packet_buffer: Arc<LatestValueBuffer<RenderPacket>>,
        on_kernel_phase: Arc<dyn Fn(EngineKernelPhase, EngineKernelPhaseContext) + Send + Sync>,
        on_frame_ready: Arc<dyn Fn(SimulationFrameReport) + Send + Sync>,
        on_particle_simulation_events_applied: Arc<
            dyn Fn(ParticleSimulationEventApplyReport) + Send + Sync,
        >,
        on_packet_published: Arc<dyn Fn() + Send + Sync>,
        initial_scene_runtime: Option<SceneRuntime>,
    ) -> Self {
        let script_runtime = ScriptRuntime::new();
        let mut scene_runtime = match initial_scene_runtime {
            Some(scene_runtime) => scene_runtime,
            None => {
                let mut scene_runtime = SceneRuntime::new(ComponentRegistry::built_in());
                scene_runtime.bootstrap_editor_preview_scene();
                scene_runtime
            }
        };
        scene_runtime.set_script_driver(SharedRuntimeScriptDriver::new(Box::new(
            script_runtime.clone(),
        )));
        // The scene's script driver keeps its own clone of the runtime's
        // shared state, so the worker does not need to store it.
        drop(script_runtime);
        let mut state = SimulationState {
            scene_runtime,
            asset_pipeline: AssetPipeline::new(),
            audio_engine: AudioEngine::with_default_backend(),
            simulation_time_seconds: 0.0,
        };

        let (sender, receiver) = channel::<SimulationCommand>();
        let handle = std::thread::Builder::new()
            .name("com.cove.engine.simulation".to_string())
            .spawn(move || {
                while let Ok(command) = receiver.recv() {
                    match command {
                        SimulationCommand::Shutdown => return,
                        SimulationCommand::Frame(request) => {
                            process(
                                &mut state,
                                &runtime,
                                &packet_buffer,
                                &on_kernel_phase,
                                &on_frame_ready,
                                &on_packet_published,
                                *request,
                            );
                        }
                        SimulationCommand::ParticleSnapshots(snapshots) => {
                            if snapshots.is_empty() {
                                continue;
                            }
                            let report = apply_particle_simulation_event_snapshots(
                                &mut state.scene_runtime,
                                &snapshots,
                            );
                            on_particle_simulation_events_applied(report);
                        }
                    }
                }
            })
            .ok();
        SimulationThread {
            sender,
            handle: Mutex::new(handle),
        }
    }

    pub fn submit(&self, request: SimulationFrameRequest) {
        let _ = self
            .sender
            .send(SimulationCommand::Frame(Box::new(request)));
    }

    pub fn submit_particle_simulation_event_snapshots(
        &self,
        snapshots: Vec<GPUParticleSimulationEventSnapshot>,
    ) {
        if snapshots.is_empty() {
            return;
        }
        let _ = self
            .sender
            .send(SimulationCommand::ParticleSnapshots(snapshots));
    }

    pub fn shutdown(&self) {
        let _ = self.sender.send(SimulationCommand::Shutdown);
        let handle = self
            .handle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }
}

impl Drop for SimulationThread {
    fn drop(&mut self) {
        let _ = self.sender.send(SimulationCommand::Shutdown);
    }
}

#[allow(clippy::too_many_arguments)]
fn process(
    state: &mut SimulationState,
    runtime: &Arc<dyn EngineRuntime>,
    packet_buffer: &LatestValueBuffer<RenderPacket>,
    on_kernel_phase: &Arc<dyn Fn(EngineKernelPhase, EngineKernelPhaseContext) + Send + Sync>,
    on_frame_ready: &Arc<dyn Fn(SimulationFrameReport) + Send + Sync>,
    on_packet_published: &Arc<dyn Fn() + Send + Sync>,
    request: SimulationFrameRequest,
) {
    let frame_context = EngineKernelPhaseContext::new(
        request.frame_index as u64,
        request.delta_time,
        request.input_events.clone(),
    );

    let begin = Instant::now();
    on_kernel_phase(EngineKernelPhase::Input, frame_context.clone());
    runtime.tick_input(request.delta_time, &request.input_events);
    let input_seconds = begin.elapsed().as_secs_f64();

    let begin = Instant::now();
    on_kernel_phase(EngineKernelPhase::Simulation, frame_context.clone());
    runtime.tick_simulation(request.delta_time);
    if request.render_scene_override.is_none() {
        state.scene_runtime.tick(
            request.delta_time,
            request.frame_index as u64,
            request.input_events.clone(),
        );
        state
            .audio_engine
            .tick(state.scene_runtime.world(), Float3::ZERO);
    }
    state.simulation_time_seconds += request.delta_time;
    let simulation_seconds = begin.elapsed().as_secs_f64();

    let begin = Instant::now();
    on_kernel_phase(EngineKernelPhase::RenderPrepare, frame_context);
    runtime.tick_render_prepare(request.delta_time);
    let _ = state.asset_pipeline.validate_path("Content");
    let render_prepare_seconds = begin.elapsed().as_secs_f64();

    if request.should_render {
        let scene = request
            .render_scene_override
            .clone()
            .unwrap_or_else(|| state.scene_runtime.render_scene());
        let palette_map = request
            .joint_palette_override
            .clone()
            .or_else(|| state.scene_runtime.resource::<JointPaletteMap>())
            .unwrap_or_default();
        let canvas = request
            .in_game_canvas_override
            .clone()
            .or_else(|| state.scene_runtime.resource::<InGameCanvas>())
            .unwrap_or_default();
        let mut packet = RenderPacket::new(
            request.frame_index,
            request.delta_time,
            request.drawable_size,
            scene,
            request
                .scene_snapshot_override
                .unwrap_or_else(|| state.scene_runtime.snapshot()),
            request.render_settings,
            state.simulation_time_seconds,
            palette_map,
            canvas,
        );
        packet.mipmapped_viewport_output = request.mipmapped_viewport_output;
        packet_buffer.publish(packet);
        on_packet_published();
    }

    on_frame_ready(SimulationFrameReport::new(
        request.frame_index,
        request.delta_time,
        input_seconds,
        simulation_seconds,
        render_prepare_seconds,
        request.should_render,
    ));
}

#[allow(clippy::too_many_arguments)]
fn apply_particle_simulation_event_snapshots(
    scene_runtime: &mut SceneRuntime,
    snapshots: &[GPUParticleSimulationEventSnapshot],
) -> ParticleSimulationEventApplyReport {
    let total_readback_event_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.total_event_count as i64)
        .sum();
    let dropped_readback_event_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.dropped_event_count as i64)
        .sum();
    let gpu_alive_particle_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.alive_particle_count as i64)
        .sum();
    let gpu_expired_particle_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.expired_particle_count as i64)
        .sum();
    let gpu_collision_event_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.collision_event_count as i64)
        .sum();
    let gpu_spawned_particle_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.gpu_spawned_particle_count as i64)
        .sum();
    let gpu_dropped_spawn_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.gpu_dropped_spawn_count as i64)
        .sum();
    let gpu_compacted_particle_count: i64 = snapshots
        .iter()
        .map(|snapshot| snapshot.compacted_particle_count as i64)
        .sum();
    let mut events_by_entity: BTreeMap<EntityID, Vec<ParticleEvent>> = BTreeMap::new();
    for snapshot in snapshots {
        let Some(raw_value) = snapshot.emitter_raw_value else {
            continue;
        };
        let events = snapshot.make_particle_events();
        if events.is_empty() {
            continue;
        }
        events_by_entity
            .entry(EntityID::from_raw_value(raw_value))
            .or_default()
            .extend(events);
    }
    if events_by_entity.is_empty() {
        let report = ParticleSimulationEventApplyReport {
            total_readback_event_count,
            dropped_readback_event_count,
            gpu_alive_particle_count,
            gpu_expired_particle_count,
            gpu_collision_event_count,
            gpu_spawned_particle_count,
            gpu_dropped_spawn_count,
            gpu_compacted_particle_count,
            ..ParticleSimulationEventApplyReport::default()
        };
        scene_runtime.apply_particle_simulation_readback_stats(&report);
        return report;
    }
    let mut report = scene_runtime.apply_particle_simulation_events(&events_by_entity);
    report.total_readback_event_count = total_readback_event_count;
    report.dropped_readback_event_count = dropped_readback_event_count;
    report.gpu_alive_particle_count = gpu_alive_particle_count;
    report.gpu_expired_particle_count = gpu_expired_particle_count;
    report.gpu_collision_event_count = gpu_collision_event_count;
    report.gpu_spawned_particle_count = gpu_spawned_particle_count;
    report.gpu_dropped_spawn_count = gpu_dropped_spawn_count;
    report.gpu_compacted_particle_count = gpu_compacted_particle_count;
    scene_runtime.apply_particle_simulation_readback_stats(&report);
    report
}
