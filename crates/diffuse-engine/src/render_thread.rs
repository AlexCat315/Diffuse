//! Translation of Engine/Sources/EngineCore/RenderThread.swift.
//!
//! One render worker per host. `request_render` only wakes the worker; the
//! worker drains the latest packet buffer, so a burst of requests collapses to
//! the newest packet.

use std::sync::Arc;
use std::sync::mpsc::{Sender, channel};
use std::thread::JoinHandle;
use std::time::Instant;

use diffuse_kernel::engine_kernel::{EngineKernelPhase, EngineKernelPhaseContext};
use diffuse_render::RenderPacket;
use diffuse_render::core::frame::render_packet::RenderPacketConsumer;
use diffuse_render::core::render_stats::{GPUParticleSimulationEventSnapshot, RenderFrameStats};
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

use crate::engine_core::EngineRuntime;
use crate::latest_value_buffer::LatestValueBuffer;

#[derive(Clone)]
pub struct RenderThreadReport {
    pub frame_index: i64,
    pub delta_time: f64,
    pub render_submit_seconds: f64,
    pub stats: RenderFrameStats,
    pub viewport_surface_state: ViewportSurfaceState,
    pub particle_simulation_event_snapshots: Vec<GPUParticleSimulationEventSnapshot>,
}

impl RenderThreadReport {
    pub fn new(
        frame_index: i64,
        delta_time: f64,
        render_submit_seconds: f64,
        stats: RenderFrameStats,
        viewport_surface_state: ViewportSurfaceState,
    ) -> Self {
        RenderThreadReport {
            frame_index,
            delta_time,
            render_submit_seconds,
            stats,
            viewport_surface_state,
            particle_simulation_event_snapshots: Vec::new(),
        }
    }

    pub fn with_snapshots(
        frame_index: i64,
        delta_time: f64,
        render_submit_seconds: f64,
        stats: RenderFrameStats,
        viewport_surface_state: ViewportSurfaceState,
        particle_simulation_event_snapshots: Vec<GPUParticleSimulationEventSnapshot>,
    ) -> Self {
        RenderThreadReport {
            frame_index,
            delta_time,
            render_submit_seconds,
            stats,
            viewport_surface_state,
            particle_simulation_event_snapshots,
        }
    }
}

enum RenderCommand {
    Render,
    Shutdown,
}

pub struct RenderThread {
    sender: Sender<RenderCommand>,
    handle: std::sync::Mutex<Option<JoinHandle<()>>>,
}

impl RenderThread {
    pub fn new(
        runtime: Arc<dyn EngineRuntime>,
        packet_buffer: Arc<LatestValueBuffer<RenderPacket>>,
        on_kernel_phase: Arc<dyn Fn(EngineKernelPhase, EngineKernelPhaseContext) + Send + Sync>,
        mut consumer: Box<dyn RenderPacketConsumer>,
        on_frame_rendered: Arc<dyn Fn(RenderThreadReport) + Send + Sync>,
    ) -> Self {
        consumer.initialize();
        let (sender, receiver) = channel::<RenderCommand>();
        let handle = std::thread::Builder::new()
            .name("com.cove.engine.render".to_string())
            .spawn(move || {
                run_render_loop(
                    receiver,
                    runtime,
                    packet_buffer,
                    on_kernel_phase,
                    consumer,
                    on_frame_rendered,
                );
            })
            .ok();
        RenderThread {
            sender,
            handle: std::sync::Mutex::new(handle),
        }
    }

    pub fn request_render(&self) {
        let _ = self.sender.send(RenderCommand::Render);
    }

    pub fn shutdown(&self) {
        let _ = self.sender.send(RenderCommand::Shutdown);
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

impl Drop for RenderThread {
    fn drop(&mut self) {
        let _ = self.sender.send(RenderCommand::Shutdown);
    }
}

fn run_render_loop(
    receiver: std::sync::mpsc::Receiver<RenderCommand>,
    runtime: Arc<dyn EngineRuntime>,
    packet_buffer: Arc<LatestValueBuffer<RenderPacket>>,
    on_kernel_phase: Arc<dyn Fn(EngineKernelPhase, EngineKernelPhaseContext) + Send + Sync>,
    mut consumer: Box<dyn RenderPacketConsumer>,
    on_frame_rendered: Arc<dyn Fn(RenderThreadReport) + Send + Sync>,
) {
    while let Ok(command) = receiver.recv() {
        if matches!(command, RenderCommand::Shutdown) {
            return;
        }
        // Collapse every wakeup already queued: the buffer keeps only the
        // newest packet either way, so extra round trips would be wasted.
        while let Ok(next) = receiver.try_recv() {
            if matches!(next, RenderCommand::Shutdown) {
                return;
            }
        }
        while let Some(packet) = packet_buffer.consume_latest() {
            let begin = Instant::now();
            on_kernel_phase(
                EngineKernelPhase::RenderSubmit,
                EngineKernelPhaseContext::new(
                    packet.frame_index as u64,
                    packet.delta_time,
                    Vec::new(),
                ),
            );
            runtime.tick_render_submit(packet.delta_time);
            consumer.render(&packet);
            let particle_simulation_event_snapshots = consumer
                .drain_gpu_particle_simulation_event_snapshots(64)
                .unwrap_or_default();
            let render_submit_seconds = begin.elapsed().as_secs_f64();

            on_frame_rendered(RenderThreadReport::with_snapshots(
                packet.frame_index,
                packet.delta_time,
                render_submit_seconds,
                consumer.current_frame_stats(),
                consumer.current_viewport_surface_state(),
                particle_simulation_event_snapshots,
            ));
        }
    }
}
