//! Translation of Editor/Sources/EditorCore/Rendering/HUD/Renderer.swift.
//!
//! Render-thread consumer of HUD snapshots. Scene and UI commands are submitted
//! together, preserving scene color and sampling only the packet's used extent.

use std::sync::{Arc, Mutex, MutexGuard};

use cove_graphics::rhi::{Device, RhiError, RhiResult, TextureFormat, TextureUploadRegion};
use cove_graphics::ui::{NativeDrawListRenderer, NativeUIViewport};
use cove_ui_compose::scene_core::DrawList;
use diffuse_render::RenderPacket;
use diffuse_render::surface::in_game_ui_providing::{
    InGameUIProviding, InGameUIRecording, InGameUIRecordingOutcome, InGameUIRecordingOutcomeError,
    NativeInGameUITarget,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use crate::rendering::hud::atlas_delivery::InGameUIAtlasDelivery;
use crate::rendering::hud::snapshots::InGameDrawListSource;

struct RendererState {
    renderer: NativeDrawListRenderer,
    list: DrawList,
    atlas_delivery: InGameUIAtlasDelivery,
}

pub struct NativeInGameUIRenderer {
    device: Arc<Device>,
    source: Arc<InGameDrawListSource>,
    state: Mutex<RendererState>,
}

impl NativeInGameUIRenderer {
    pub fn new(device: Arc<Device>, source: Arc<InGameDrawListSource>) -> RhiResult<Self> {
        let renderer = NativeDrawListRenderer::new(device.clone())?;
        Ok(NativeInGameUIRenderer {
            device,
            source,
            state: Mutex::new(RendererState {
                renderer,
                list: DrawList::default(),
                atlas_delivery: InGameUIAtlasDelivery::default(),
            }),
        })
    }

    fn state(&self) -> MutexGuard<'_, RendererState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl InGameUIProviding for NativeInGameUIRenderer {
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        _snapshot: &SceneRuntimeSnapshot,
        mut target: NativeInGameUITarget,
    ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
        let mut state = self.state();
        if !Arc::ptr_eq(&target.device, &self.device) {
            return Err(InGameUIRecordingOutcome::failed(
                target.commands,
                RhiError::invalid_argument("native HUD requires the scene's NativeRHI device"),
            ));
        }
        let Some(snapshot) = self.source.consume() else {
            state.list.reset();
            return Ok(InGameUIRecordingOutcome::new(target.commands, None));
        };
        state.atlas_delivery.collect(&snapshot);
        let RendererState {
            renderer,
            list,
            atlas_delivery,
        } = &mut *state;
        if let Err(error) = renderer.configure(target.format, target.sample_count) {
            return Err(InGameUIRecordingOutcome::failed(target.commands, error));
        }
        let staged = atlas_delivery.stage(|update| {
            let region = TextureUploadRegion::with_origin(
                i64::from(update.region_width),
                i64::from(update.region_height),
                i64::from(update.region_x),
                i64::from(update.region_y),
            );
            renderer.register_texture(
                update.texture_id,
                update.pixels.clone(),
                [
                    update.texture_width as usize,
                    update.texture_height as usize,
                ],
                region,
                if update.format == cove_ui_compose::scene_core::GlyphAtlasFormat::Alpha {
                    TextureFormat::R8Unorm
                } else {
                    TextureFormat::Rgba8Unorm
                },
            )
        });
        if let Err(error) = staged {
            return Err(InGameUIRecordingOutcome::failed(target.commands, error));
        }
        let logical_size = snapshot.logical_size;
        let is_empty = snapshot.is_empty();
        if let Err(error) = list.load(
            snapshot.vertices,
            snapshot.indices,
            snapshot.batches,
            snapshot.resources,
        ) {
            return Err(InGameUIRecordingOutcome::failed(
                target.commands,
                RhiError::invalid_argument(error.to_string()),
            ));
        }
        if is_empty {
            return Ok(InGameUIRecordingOutcome::new(target.commands, None));
        }
        let viewport = NativeUIViewport::new(
            [
                packet.drawable_size.width as usize,
                packet.drawable_size.height as usize,
            ],
            logical_size,
        );
        match renderer.record(list, &mut target.commands, target.color, viewport, None) {
            Ok(frame) => {
                let draw_call_count = frame.statistics.draw_calls;
                let mut frame = frame;
                Ok(InGameUIRecordingOutcome::new(
                    target.commands,
                    Some(InGameUIRecording::new(draw_call_count, move || {
                        frame.did_submit();
                    })),
                ))
            }
            Err(error) => Err(InGameUIRecordingOutcome::failed(target.commands, error)),
        }
    }
}
