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
use diffuse_render::surface::in_game_ui_providing::InGameUIProviding;

use crate::rendering::hud::renderer::NativeInGameUIRenderer;
use crate::rendering::hud::snapshots::InGameDrawListSource;
use crate::rendering::hud::view_graph::InGameViewGraphBridge;

pub struct InGameUIHost {
    /// Main-thread view pipeline. Touched only by `set_root_view`/`tick`.
    bridge: RefCell<InGameViewGraphBridge>,
    renderer: Arc<NativeInGameUIRenderer>,
}

impl InGameUIHost {
    /// Native HUD and scene must share the same device and active frame.
    pub fn new(device: Arc<Device>) -> RhiResult<Self> {
        let source = Arc::new(InGameDrawListSource::new());
        let bridge = InGameViewGraphBridge::new(source.clone());
        let renderer = NativeInGameUIRenderer::new(device, source)?;
        Ok(InGameUIHost {
            bridge: RefCell::new(bridge),
            renderer: Arc::new(renderer),
        })
    }

    pub fn render_provider(&self) -> Box<dyn InGameUIProviding> {
        Box::new(Arc::clone(&self.renderer))
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
