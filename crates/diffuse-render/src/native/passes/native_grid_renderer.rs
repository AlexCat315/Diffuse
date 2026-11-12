//! An isolated RenderPacketConsumer for validating the migrated editor-grid
//! pass. Full scene meshes and post processing belong to NativeRenderer.
//! This consumer supports native windows and offscreen NativeRHI textures;
//! offscreen output is published as an owned NativeRHI image for UI sampling.

use std::sync::Arc;

use std::sync::Mutex;

use cove_graphics::rhi::{
    CommandBuffer, Device, RenderColorTarget, RenderDepthTarget, RenderPassDescriptor, Texture,
};
use cove_logging::{Level, LogEvent};

use crate::core::frame::render_frame_plan::RenderPassKind;
use crate::core::frame::render_packet::{RenderDrawableSize, RenderPacket, RenderPacketConsumer};
use crate::core::render_stats::RenderFrameStats;
use crate::native::passes::native_editor_grid_pass::NativeEditorGridPass;
use crate::native::targets::native_render_targets::NativeRenderTargets;
use crate::native::targets::native_window_target::NativeWindowTarget;
use crate::support::log;
use crate::surface::viewport_surface::{
    ViewportSamplingRegion, ViewportSurfacePublication, ViewportSurfaceState,
};

pub struct NativeGridRenderer {
    pub device: Arc<Device>,
    grid: NativeEditorGridPass,
    window_target: Option<NativeWindowTarget>,
    targets: Mutex<Option<NativeRenderTargets>>,
    viewport_publication: Mutex<ViewportSurfacePublication>,
    last_frame_stats: Mutex<RenderFrameStats>,
    last_error: Mutex<Option<String>>,
}

// Keep the Swift `defer { device.endFrame() }` on every return path.
struct FrameEnd(Arc<Device>);
impl Drop for FrameEnd {
    fn drop(&mut self) {
        self.0.end_frame();
    }
}

impl Drop for NativeGridRenderer {
    fn drop(&mut self) {
        let _ = self.device.with_frame_session(|| {
            self.grid.destroy();
            Ok(())
        });
    }
}

impl NativeGridRenderer {
    pub fn new(
        device: &Arc<Device>,
        surface: Option<crate::core::frame::render_packet::RenderSurfaceDescriptor>,
    ) -> Result<Self, cove_graphics::rhi::RhiError> {
        let window_target = surface.map(|surface| NativeWindowTarget::new(device.clone(), surface));
        let grid = NativeEditorGridPass::new(device)?;
        Ok(NativeGridRenderer {
            device: device.clone(),
            grid,
            window_target,
            targets: Mutex::new(None),
            viewport_publication: Mutex::new(ViewportSurfacePublication::default()),
            last_frame_stats: Mutex::new(RenderFrameStats::default()),
            last_error: Mutex::new(None),
        })
    }

    pub fn initialize(&self) {
        log::renderer().log(&LogEvent::new(
            Level::Info,
            format!(
                "NativeRHI editor-grid renderer ready ({})",
                self.device.device_name()
            ),
        ));
    }

    pub fn render(&self, packet: &RenderPacket) {
        match self.render_checked(packet) {
            Ok(()) => {}
            Err(error) => {
                *self
                    .last_error
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(error.to_string());
                log::renderer().log(&LogEvent::new(
                    Level::Error,
                    format!("native grid render failed: {error}"),
                ));
            }
        }
    }

    pub fn current_frame_stats(&self) -> RenderFrameStats {
        self.last_frame_stats
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    pub fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        self.viewport_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .state
            .clone()
    }

    /// Borrowed handle; a viewport surface owns the output across replacement.
    pub fn color_texture(&self) -> Option<Texture> {
        self.targets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .and_then(|targets| targets.color.as_ref().map(|color| color.texture()))
    }

    /// Throwing entry point used by tools/tests so a failed render cannot be
    /// mistaken for a successful frame or a performance sample.
    pub fn render_checked(
        &self,
        packet: &RenderPacket,
    ) -> Result<(), cove_graphics::rhi::RhiError> {
        self.device.with_frame_session(|| self.render_frame(packet))
    }

    fn render_frame(&self, packet: &RenderPacket) -> Result<(), cove_graphics::rhi::RhiError> {
        let start = std::time::Instant::now();
        if packet.drawable_size.width == 0
            || packet.drawable_size.height == 0
            || (packet.render_settings.viewport.grid_enabled
                && !packet.render_settings.viewport.grid_spacing.is_finite())
        {
            return Err(cove_graphics::rhi::RhiError::invalid_argument(
                "native grid viewport must be nonempty",
            ));
        }
        self.ensure_targets(packet.drawable_size)?;
        let targets_guard = self
            .targets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(targets) = targets_guard.as_ref() else {
            return Err(cove_graphics::rhi::RhiError::OutOfMemory);
        };
        self.device.begin_frame()?;
        let _frame = FrameEnd(self.device.clone());
        let image = self
            .window_target
            .as_ref()
            .map(|target| target.acquire())
            .transpose()?;
        let Some(color) = image
            .as_ref()
            .map(|image| image.texture)
            .or_else(|| targets.color.as_ref().map(|color| color.texture()))
        else {
            drop(targets_guard);

            return Err(cove_graphics::rhi::RhiError::SwapchainAcquireFailed(
                "no grid color target".into(),
            ));
        };
        let prepared = start.elapsed();
        let mut commands = CommandBuffer::new();
        let color_target = RenderColorTarget::clearing(color, [0.08, 0.10, 0.14, 1.0]);
        let depth_target = RenderDepthTarget::new(targets.depth.texture());
        if packet.render_settings.viewport.grid_enabled {
            self.grid
                .encode(packet, color_target, depth_target, &mut commands)?;
        } else {
            commands.render_pass(
                RenderPassDescriptor::new(vec![color_target]).with_depth(depth_target),
                |_| {},
            );
        }
        let encoded = start.elapsed();
        self.device.submit(
            &commands,
            cove_graphics::rhi::QueueClass::Graphics,
            &[],
            &[],
            None,
        )?;
        if let Some(output) = targets.color.as_ref() {
            self.viewport_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .publish(
                    output.clone(),
                    Vec::new(),
                    ViewportSamplingRegion::new(packet.drawable_size, targets.size),
                );
        } else {
            self.viewport_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear();
        }
        if let Some(image) = image {
            self.device.present(image)?;
        }
        drop(targets_guard);

        drop(_frame);
        let submitted = start.elapsed();
        let mut stats = RenderFrameStats {
            frame_index: packet.frame_index,
            pass_count: 1,
            draw_call_count: if packet.render_settings.viewport.grid_enabled {
                1
            } else {
                0
            },
            active_passes: if packet.render_settings.viewport.grid_enabled {
                vec![RenderPassKind::EditorGrid]
            } else {
                Vec::new()
            },
            ..RenderFrameStats::default()
        };
        let mut pass_draw_call_counts = std::collections::BTreeMap::new();
        pass_draw_call_counts.insert(RenderPassKind::EditorGrid, stats.draw_call_count);
        stats.pass_draw_call_counts = pass_draw_call_counts;
        stats.cpu_prepare_ns = prepared.as_nanos() as u64;
        stats.cpu_encode_ns = (encoded - prepared).as_nanos() as u64;
        stats.cpu_submit_ns = (submitted - encoded).as_nanos() as u64;
        stats.cpu_frame_total_ns = submitted.as_nanos() as u64;
        let mut pass_encode_ns = std::collections::BTreeMap::new();
        pass_encode_ns.insert(RenderPassKind::EditorGrid, stats.cpu_encode_ns);
        stats.pass_encode_ns = pass_encode_ns;
        *self
            .last_frame_stats
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = stats;
        *self
            .last_error
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        Ok(())
    }

    fn ensure_targets(&self, size: RenderDrawableSize) -> Result<(), cove_graphics::rhi::RhiError> {
        let mut guard = self
            .targets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if guard.as_ref().is_some_and(|targets| targets.size == size) {
            return Ok(());
        }
        if let Some(window_target) = &self.window_target {
            window_target.configure(size)?;
        }
        let replacement =
            NativeRenderTargets::make(&self.device, size, self.window_target.is_none(), false)?;
        *guard = Some(replacement);
        Ok(())
    }
}

impl RenderPacketConsumer for NativeGridRenderer {
    fn initialize(&mut self) {
        NativeGridRenderer::initialize(self);
    }

    fn render(&mut self, packet: &RenderPacket) {
        NativeGridRenderer::render(self, packet);
    }

    fn current_frame_stats(&self) -> RenderFrameStats {
        NativeGridRenderer::current_frame_stats(self)
    }

    fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        NativeGridRenderer::current_viewport_surface_state(self)
    }
}
