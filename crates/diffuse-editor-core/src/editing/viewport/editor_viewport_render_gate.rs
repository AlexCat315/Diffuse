//! `Editor/Sources/EditorCore/Editing/Viewport/EditorViewportRenderGate.swift`.

use diffuse_render::core::frame::render_packet::RenderDrawableSize;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_geometry_overlay::RenderGeometryOverlay;
use diffuse_scene::rendering::render_scene::RenderCamera;

/// Decides whether the engine should render the viewport this tick.
///
/// The signature samples the values that feed `RenderPacket` — a closed set:
/// if none changed, re-rendering would produce an identical image, so the
/// tick skips the GPU entirely (the editor stays on the last published
/// texture). A false-dirty merely degrades to continuous rendering; a missed
/// invalidation is caught by the heartbeat and the realtime toggle.
#[derive(Clone, Debug, Default)]
pub struct EditorViewportRenderGate {
    last_signature: Option<EditorViewportRenderGateSignature>,
    last_render_time: f64,
    pending_frames: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorViewportRenderGateSignature {
    pub scene_revision: u64,
    pub camera: RenderCamera,
    pub drawable_size: RenderDrawableSize,
    pub settings_generation: u64,
    pub joint_palettes: JointPaletteMap,
    pub geometry_overlays: Vec<RenderGeometryOverlay>,
}

impl EditorViewportRenderGateSignature {
    /// Swift's memberwise initializer; `geometryOverlays` defaults to empty.
    pub fn new(
        scene_revision: u64,
        camera: RenderCamera,
        drawable_size: RenderDrawableSize,
        settings_generation: u64,
        joint_palettes: JointPaletteMap,
    ) -> Self {
        EditorViewportRenderGateSignature {
            scene_revision,
            camera,
            drawable_size,
            settings_generation,
            joint_palettes,
            geometry_overlays: Vec::new(),
        }
    }

    /// The full memberwise initializer.
    pub fn with_overlays(
        scene_revision: u64,
        camera: RenderCamera,
        drawable_size: RenderDrawableSize,
        settings_generation: u64,
        joint_palettes: JointPaletteMap,
        geometry_overlays: Vec<RenderGeometryOverlay>,
    ) -> Self {
        EditorViewportRenderGateSignature {
            scene_revision,
            camera,
            drawable_size,
            settings_generation,
            joint_palettes,
            geometry_overlays,
        }
    }
}

impl EditorViewportRenderGate {
    /// Missed-invalidation safety net: render at least this often while the
    /// editor ticks, so a forgotten dirty path shows up as a 1 Hz refresh
    /// instead of a frozen viewport.
    pub const HEARTBEAT_INTERVAL: f64 = 1.0;
    /// Frames rendered after the last change. Covers in-flight completion
    /// handlers and double buffering.
    pub const CONVERGENCE_FRAMES: i64 = 2;
    /// TAA needs several frames after the last change for its history to
    /// converge; stopping earlier would freeze a half-resolved image.
    pub const TEMPORAL_CONVERGENCE_FRAMES: i64 = 8;

    pub fn new() -> Self {
        EditorViewportRenderGate {
            last_signature: None,
            last_render_time: f64::NEG_INFINITY,
            pending_frames: 0,
        }
    }

    /// The full signature; `isPresentationActive` defaults to `true` in Swift.
    pub fn should_render(
        &mut self,
        signature: EditorViewportRenderGateSignature,
        force_continuous: bool,
        has_viewport_input: bool,
        temporal_effects_active: bool,
        is_presentation_active: bool,
        now: f64,
    ) -> bool {
        if !is_presentation_active {
            self.last_signature = None;
            self.pending_frames = 0;
            return false;
        }
        if self.last_signature.as_ref() != Some(&signature)
            || force_continuous
            || has_viewport_input
        {
            self.pending_frames = if temporal_effects_active {
                Self::TEMPORAL_CONVERGENCE_FRAMES
            } else {
                Self::CONVERGENCE_FRAMES
            };
        }
        let render =
            self.pending_frames > 0 || now - self.last_render_time >= Self::HEARTBEAT_INTERVAL;
        if render {
            self.last_signature = Some(signature);
            self.last_render_time = now;
            if self.pending_frames > 0 {
                self.pending_frames -= 1;
            }
        }
        render
    }

    /// Swift's `isPresentationActive: Bool = true` default.
    pub fn should_render_default(
        &mut self,
        signature: EditorViewportRenderGateSignature,
        force_continuous: bool,
        has_viewport_input: bool,
        temporal_effects_active: bool,
        now: f64,
    ) -> bool {
        self.should_render(
            signature,
            force_continuous,
            has_viewport_input,
            temporal_effects_active,
            true,
            now,
        )
    }
}
