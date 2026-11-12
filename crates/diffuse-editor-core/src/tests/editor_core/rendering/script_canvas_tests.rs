//! Ported from `Editor/Tests/EditorCoreTests/Rendering/ScriptCanvasTests.swift`.

use std::sync::{Arc, Mutex, MutexGuard};

use cove_ui_compose::scene_core::GlyphAtlasFormat;
use diffuse_kernel::in_game_canvas::{InGameCanvas, InGameUIColor};

use crate::rendering::hud::snapshots::InGameDrawListSource;
use crate::rendering::hud::view_graph::InGameViewGraphBridge;

static LOCK: Mutex<()> = Mutex::new(());

fn serialized() -> MutexGuard<'static, ()> {
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Script-only HUD publishes text and progress without a custom root view.
#[test]
fn publishes_canvas() {
    let _guard = serialized();
    let source = Arc::new(InGameDrawListSource::new());
    let mut bridge = InGameViewGraphBridge::new(source.clone());
    let mut canvas = InGameCanvas::new();
    canvas.rect_rounded(10.0, 10.0, 200.0, 90.0, InGameUIColor::BLUE, 8.0);
    canvas.label_styled("Score: 8", 20.0, 20.0, 24.0, InGameUIColor::WHITE);
    canvas.progress_bar(20.0, 60.0, 150.0, 10.0, 0.5);
    bridge.tick(640, 480, 2.0, canvas);
    let frame = source.consume().expect("frame");
    assert!(!frame.is_empty());
    assert!(!frame.vertices.is_empty());
    assert!(!frame.atlas_updates.is_empty());
    assert_eq!(frame.logical_size[0], 640.0);
    bridge.tick(640, 480, 2.0, InGameCanvas::new());
    assert!(source.consume().expect("empty frame").is_empty());
}

/// Script canvas coexists with a declarative HUD root.
#[test]
fn combines_root() {
    use cove_ui_compose::primitives::text::Text;

    let _guard = serialized();
    let source = Arc::new(InGameDrawListSource::new());
    let mut bridge = InGameViewGraphBridge::new(source.clone());
    bridge.set_root_view(Text::new("Declarative HUD"));
    bridge.tick(640, 480, 1.0, InGameCanvas::new());
    let base = source.consume().expect("base").vertices.len();
    let mut canvas = InGameCanvas::new();
    canvas.rect(100.0, 100.0, 200.0, 80.0, InGameUIColor::GREEN);
    bridge.tick(640, 480, 1.0, canvas);
    assert!(source.consume().expect("combined").vertices.len() > base);
}

/// Scale replacement rerasterizes unchanged cached script text.
#[test]
fn rerasterizes_cached_text_on_scale_change() {
    let _guard = serialized();
    let source = Arc::new(InGameDrawListSource::new());
    let mut bridge = InGameViewGraphBridge::new(source.clone());
    let mut canvas = InGameCanvas::new();
    canvas.label_styled("Score 🙂", 20.0, 20.0, 24.0, InGameUIColor::WHITE);
    bridge.tick(320, 120, 1.0, canvas.clone());
    let _ = source.consume().expect("first frame");
    bridge.tick(320, 120, 2.0, canvas);
    let replaced = source.consume().expect("replaced frame");
    assert!(!replaced.is_empty());
    assert!(replaced.atlas_updates.iter().any(|update| {
        update.format == GlyphAtlasFormat::Alpha
            && update.texture_width == 1024
            && update.pixels.iter().any(|pixel| *pixel != 0)
    }));
    #[cfg(target_os = "macos")]
    assert!(replaced.atlas_updates.iter().any(|update| {
        update.format == GlyphAtlasFormat::Color && update.pixels.iter().any(|pixel| *pixel != 0)
    }));
}

/// Script HUD delivers both atlas planes and keeps emoji after skipped frames.
#[cfg(target_os = "macos")]
#[test]
fn publishes_color_glyphs() {
    use cove_core::color_glyph_atlas_id;

    let _guard = serialized();
    let source = Arc::new(InGameDrawListSource::new());
    let mut bridge = InGameViewGraphBridge::new(source.clone());
    let mut canvas = InGameCanvas::new();
    canvas.label_styled("Score 🙂", 20.0, 20.0, 24.0, InGameUIColor::WHITE);
    bridge.tick(640, 480, 2.0, canvas.clone());
    bridge.tick(640, 480, 2.0, canvas);
    let frame = source.consume().expect("frame");
    assert_eq!(
        frame
            .atlas_updates
            .iter()
            .map(|update| update.format)
            .collect::<Vec<_>>(),
        [GlyphAtlasFormat::Alpha, GlyphAtlasFormat::Color]
    );
    assert!(
        frame
            .batches
            .iter()
            .any(|batch| batch.texture_id == color_glyph_atlas_id(1))
    );
    assert!(
        frame.atlas_updates[1]
            .pixels
            .iter()
            .any(|pixel| *pixel != 0)
    );
    assert!(
        source
            .consume()
            .expect("next frame")
            .atlas_updates
            .is_empty()
    );
}
