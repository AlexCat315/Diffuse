//! The in-game UI provider contract: CoveUI supplies HUD geometry into the
//! engine's NativeRHI frame.

use std::sync::Arc;

use cove_graphics::rhi::{CommandBuffer, Device, RenderColorTarget, TextureFormat};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use crate::core::frame::render_packet::RenderPacket;

/// A borrowed target in the scene renderer's active NativeRHI frame. The
/// provider records into these commands without beginning or submitting a frame.
pub struct NativeInGameUITarget {
    pub device: Arc<Device>,
    pub commands: CommandBuffer,
    pub color: RenderColorTarget,
    pub format: TextureFormat,
    pub sample_count: usize,
}

impl NativeInGameUITarget {
    pub fn new(
        device: Arc<Device>,
        commands: CommandBuffer,
        color: RenderColorTarget,
        format: TextureFormat,
    ) -> Self {
        NativeInGameUITarget {
            device,
            commands,
            color,
            format,
            sample_count: 1,
        }
    }
}

/// Retains a recording's borrowed resources until submission. Acknowledge only
/// after the scene command buffer was submitted; abandoned records keep updates
/// pending. This token is used serially on the render thread.
pub struct InGameUIRecording {
    pub draw_call_count: usize,
    on_submit: Option<Box<dyn FnOnce() + Send>>,
}

impl InGameUIRecording {
    pub fn new(draw_call_count: usize, on_submit: impl FnOnce() + Send + 'static) -> Self {
        InGameUIRecording {
            draw_call_count,
            on_submit: Some(Box::new(on_submit)),
        }
    }

    /// Swift's default `onSubmit` is a no-op closure.
    pub fn without_callback(draw_call_count: usize) -> Self {
        InGameUIRecording {
            draw_call_count,
            on_submit: Some(Box::new(|| {})),
        }
    }

    pub fn did_submit(&mut self) {
        if let Some(action) = self.on_submit.take() {
            action();
        }
    }
}

/// Engine owns the GPU frame; CoveUI supplies its most recent HUD geometry.
/// Called even when script canvas commands are empty: declarative HUDs can
/// still have content. Recording errors abort the entire scene submission.
pub trait InGameUIProviding: Send + Sync {
    /// Records HUD geometry into `target.commands`. The frame's command buffer
    /// is handed over owned and returned through the recording so the renderer
    /// can continue appending after the HUD pass, mirroring Swift's borrow.
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        snapshot: &SceneRuntimeSnapshot,
        target: NativeInGameUITarget,
    ) -> InGameUIRecordingOutcome;
}

/// The recorded commands plus an optional acknowledgement token. Swift hands
/// the provider a borrowed `CommandBuffer`; the RHI records into an owned
/// buffer, so the frame's buffer is round-tripped through the outcome.
pub struct InGameUIRecordingOutcome {
    pub commands: CommandBuffer,
    pub recording: Option<InGameUIRecording>,
}

impl InGameUIRecordingOutcome {
    pub fn new(commands: CommandBuffer, recording: Option<InGameUIRecording>) -> Self {
        InGameUIRecordingOutcome {
            commands,
            recording,
        }
    }

    /// Swift's throwing variant surfaces a recording error as `Err`; the frame
    /// aborts with the provider's error and keeps the (partially recorded)
    /// commands so the caller can still finish the frame cleanly.
    pub fn failed(
        commands: CommandBuffer,
        error: cove_graphics::rhi::RhiError,
    ) -> InGameUIRecordingOutcomeError {
        InGameUIRecordingOutcomeError { commands, error }
    }
}

/// A failed HUD recording: the frame aborts with the provider's error.
pub struct InGameUIRecordingOutcomeError {
    pub commands: CommandBuffer,
    pub error: cove_graphics::rhi::RhiError,
}

impl From<InGameUIRecordingOutcomeError> for cove_graphics::rhi::RhiError {
    fn from(value: InGameUIRecordingOutcomeError) -> Self {
        value.error
    }
}
