//! The per-frame render packet and the consumer protocol.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Frame/RenderPacket.swift`.

use cove_graphics::rhi::RhiError;
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::RenderScene;
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use crate::core::render_settings::RenderSettings;
use crate::core::render_stats::{GPUParticleSimulationEventSnapshot, RenderFrameStats};

/// The pixel size of the render destination.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RenderDrawableSize {
    pub width: u32,
    pub height: u32,
}

impl RenderDrawableSize {
    pub fn new(width: u32, height: u32) -> Self {
        RenderDrawableSize { width, height }
    }
}

/// `RenderSurfaceDescriptor` — the platform surface a renderer presents into.
///
/// Swift's `UnsafeMutableRawPointer` becomes `*mut c_void`; Swift marks the
/// enum `@unchecked Sendable`, so the raw pointers are forwarded behind an
/// explicit `unsafe impl Send` (MIGRATION.md §5.5).
#[derive(Clone, Copy, Debug)]
pub enum RenderSurfaceDescriptor {
    MetalLayer(*mut core::ffi::c_void),
    Win32Window {
        hwnd: *mut core::ffi::c_void,
        hinstance: Option<*mut core::ffi::c_void>,
    },
    XlibWindow {
        display: *mut core::ffi::c_void,
        window: u64,
    },
    WaylandSurface {
        display: *mut core::ffi::c_void,
        surface: *mut core::ffi::c_void,
    },
}

// SAFETY: the platform handles are opaque tokens handed to the window system;
// the packet never dereferences them, it only forwards them to the backend —
// exactly Swift's `@unchecked Sendable` promise.
unsafe impl Send for RenderSurfaceDescriptor {}

/// Everything one frame needs to render.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderPacket {
    pub frame_index: i64,
    pub delta_time: f64,
    pub drawable_size: RenderDrawableSize,
    pub scene: RenderScene,
    pub scene_snapshot: SceneRuntimeSnapshot,
    pub render_settings: RenderSettings,
    pub simulation_time_seconds: f64,
    pub joint_palette_map: JointPaletteMap,
    pub in_game_canvas: InGameCanvas,
    pub mipmapped_viewport_output: bool,
}

impl RenderPacket {
    /// Swift's defaulted initializer; `mipmappedViewportOutput` is a field
    /// default (`false`), not an argument.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        frame_index: i64,
        delta_time: f64,
        drawable_size: RenderDrawableSize,
        scene: RenderScene,
        scene_snapshot: SceneRuntimeSnapshot,
        render_settings: RenderSettings,
        simulation_time_seconds: f64,
        joint_palette_map: JointPaletteMap,
        in_game_canvas: InGameCanvas,
    ) -> Self {
        RenderPacket {
            frame_index,
            delta_time,
            drawable_size,
            scene,
            scene_snapshot,
            render_settings,
            simulation_time_seconds,
            joint_palette_map,
            in_game_canvas,
            mipmapped_viewport_output: false,
        }
    }
}

/// The renderer interface the engine drives each frame.
///
/// Swift's protocol extension gives `drainGPUParticleSimulationEventSnapshots`
/// a default implementation, so the trait method carries that default here and
/// conformers override it (NativeRenderer does in Swift). Swift's default
/// argument `Int.max` becomes `usize::MAX` at call sites.
pub trait RenderPacketConsumer: Send {
    fn initialize(&mut self);
    fn render(&mut self, packet: &RenderPacket);
    fn current_frame_stats(&self) -> RenderFrameStats;
    /// Planned path of `Engine/Sources/RenderBackend/Surface/ViewportSurface.swift`
    /// (`ViewportSurfaceState`), owned by the surface batch.
    fn current_viewport_surface_state(
        &self,
    ) -> crate::surface::viewport_surface::ViewportSurfaceState;
    fn drain_gpu_particle_simulation_event_snapshots(
        &mut self,
        max_snapshots: usize,
    ) -> Result<Vec<GPUParticleSimulationEventSnapshot>, RhiError> {
        let _ = max_snapshots;
        Ok(Vec::new())
    }
}
