//! Translation of Editor/Sources/EditorCore/Rendering/HUD/InGameUIHost.swift.
//!
//! High-level in-game UI host that wires the full CoveUI ViewGraph pipeline for
//! rendering 2-D HUD overlays on top of a 3-D scene.
//!
//! ## Threading
//! - `set_root_view` and `tick` must be called on the **main thread**.
//! - `record_in_game_ui` (via [`InGameUIProviding`]) is called on the **render
//!   thread** and reads the last snapshot published by `tick`.

use std::cell::RefCell;
use std::sync::Arc;

use cove_graphics::rhi::{Device, RhiResult};
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_render::RenderPacket;
use diffuse_render::surface::in_game_ui_providing::{
    InGameUIProviding, InGameUIRecordingOutcome, InGameUIRecordingOutcomeError,
    NativeInGameUITarget,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use crate::rendering::hud::renderer::NativeInGameUIRenderer;
use crate::rendering::hud::snapshots::InGameDrawListSource;
use crate::rendering::hud::view_graph::InGameViewGraphBridge;

pub struct InGameUIHost {
    /// Main-thread view pipeline. Touched only by `set_root_view`/`tick`.
    bridge: RefCell<InGameViewGraphBridge>,
    renderer: NativeInGameUIRenderer,
}

// SAFETY: Swift declares `InGameUIHost: @unchecked Sendable` with the same
// contract this port keeps: the `ViewGraph` pipeline (`bridge`) is main-thread
// state, reached only from `set_root_view` and `tick`, while the render thread
// reaches the renderer's snapshot channel (`InGameDrawListSource`, a `Mutex`).
// The two halves never share `Rc` state, and `InGameUIRecordingOutcome` hands
// the command buffer back before any other thread observes it.
unsafe impl Send for InGameUIHost {}
// SAFETY: `&InGameUIHost` is exposed to the render thread through
// `InGameUIProviding`. Every `&self` method that touches `bridge` is documented
// as main-thread-only, and `tick` takes `&self` only because Swift's class API
// does; `RefCell` enforcement would panic on a cross-thread call rather than
// corrupt the tree. `record_in_game_ui` never borrows `bridge`; it locks the
// renderer state instead.
unsafe impl Sync for InGameUIHost {}

impl InGameUIHost {
    /// Native HUD and scene must share the same device and active frame.
    pub fn new(device: Arc<Device>) -> RhiResult<Self> {
        let source = Arc::new(InGameDrawListSource::new());
        let bridge = InGameViewGraphBridge::new(source.clone());
        let renderer = NativeInGameUIRenderer::new(device, source)?;
        Ok(InGameUIHost {
            bridge: RefCell::new(bridge),
            renderer,
        })
    }

    /// Install a CoveUI view tree as the in-game HUD.
    /// Call once before the first `tick`. Ignored on subsequent calls.
    pub fn set_root_view(&self, view: impl cove_ui_compose::View + 'static) {
        self.bridge.borrow_mut().set_root_view(view);
    }

    /// Advance the in-game UI one frame. Call on the **main thread** every
    /// frame — typically inside the `onTick` callback passed to `Application.run`.
    /// `width`/`height` are logical points; pass the window's content scale so
    /// HUD text rasterizes at physical-pixel resolution.
    pub fn tick(&self, width: u32, height: u32, content_scale: f32, canvas: InGameCanvas) {
        self.bridge
            .borrow_mut()
            .tick(width, height, content_scale, canvas);
    }

    /// `tick(width:height:)` with Swift's default content scale and canvas.
    pub fn tick_default(&self, width: u32, height: u32) {
        self.tick(width, height, 1.0, InGameCanvas::new());
    }
}

impl InGameUIProviding for InGameUIHost {
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        snapshot: &SceneRuntimeSnapshot,
        target: NativeInGameUITarget,
    ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
        self.renderer.record_in_game_ui(packet, snapshot, target)
    }
}
