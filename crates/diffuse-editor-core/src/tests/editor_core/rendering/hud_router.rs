//! Ported from `Editor/Tests/EditorCoreTests/Rendering/HUDRouter.swift`.

use std::sync::{Arc, Mutex, MutexGuard};

use cove_graphics::rhi::{CommandBuffer, Device, RenderColorTarget, TextureFormat};
use diffuse_render::RenderPacket;
use diffuse_render::surface::in_game_ui_providing::{
    InGameUIProviding, InGameUIRecordingOutcome, InGameUIRecordingOutcomeError,
    NativeInGameUITarget,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

/// A test-scoped provider allows failure and enable/disable cases to share
/// one renderer without installing process-wide state. The provider is shared
/// by handle so the reference renderer and the test observe the same route.
#[derive(Clone, Default)]
pub struct HUDRouter {
    provider: Arc<Mutex<Option<Box<dyn InGameUIProviding>>>>,
}

impl HUDRouter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_provider(&self, provider: Option<Box<dyn InGameUIProviding>>) {
        *self.lock() = provider;
    }

    pub fn has_provider(&self) -> bool {
        self.lock().is_some()
    }

    fn lock(&self) -> MutexGuard<'_, Option<Box<dyn InGameUIProviding>>> {
        self.provider
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl InGameUIProviding for HUDRouter {
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        snapshot: &SceneRuntimeSnapshot,
        target: NativeInGameUITarget,
    ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
        match self.lock().as_ref() {
            Some(provider) => provider.record_in_game_ui(packet, snapshot, target),
            None => Ok(InGameUIRecordingOutcome::new(target.commands, None)),
        }
    }
}

/// Serializes tests that touch process-wide UI state.
pub enum GlobalTestLock {}
impl GlobalTestLock {
    pub fn locked<T>(action: impl FnOnce() -> T) -> T {
        static LOCK: Mutex<()> = Mutex::new(());
        let _guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        action()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use cove_graphics::rhi::{DeviceConfig, Texture};
    use diffuse_kernel::in_game_canvas::InGameCanvas;
    use diffuse_render::RenderDrawableSize;
    use diffuse_render::core::render_settings::RenderSettings;
    use diffuse_scene::media::animation::JointPaletteMap;
    use diffuse_scene::rendering::render_scene::RenderScene;

    fn packet() -> RenderPacket {
        let mut packet = RenderPacket::new(
            0,
            0.0,
            RenderDrawableSize::new(128, 64),
            RenderScene::default(),
            SceneRuntimeSnapshot::new(0, 0),
            RenderSettings::default(),
            0.0,
            JointPaletteMap::default(),
            InGameCanvas::default(),
        );
        packet.mipmapped_viewport_output = false;
        packet
    }

    fn target(device: Arc<Device>) -> NativeInGameUITarget {
        NativeInGameUITarget::new(
            device,
            CommandBuffer::new(),
            RenderColorTarget::new(Texture::new(0)),
            TextureFormat::Bgra8Unorm,
        )
    }

    struct CountingProvider {
        calls: Arc<AtomicUsize>,
    }

    impl InGameUIProviding for CountingProvider {
        fn record_in_game_ui(
            &self,
            _packet: &RenderPacket,
            _snapshot: &SceneRuntimeSnapshot,
            target: NativeInGameUITarget,
        ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            Ok(InGameUIRecordingOutcome::new(target.commands, None))
        }
    }

    #[test]
    fn routes_to_provider_and_passes_through_without_one() {
        GlobalTestLock::locked(routes_to_provider_and_passes_through_without_one_body);
    }

    fn routes_to_provider_and_passes_through_without_one_body() {
        let device = Arc::new(Device::make(DeviceConfig::default()).expect("test device"));
        let snapshot = SceneRuntimeSnapshot::new(0, 0);
        let packet = packet();

        let router = HUDRouter::default();
        let Ok(outcome) = router.record_in_game_ui(&packet, &snapshot, target(device.clone()))
        else {
            panic!("no provider still records nothing");
        };
        assert!(outcome.recording.is_none());

        let calls = Arc::new(AtomicUsize::new(0));
        let router = HUDRouter::new();
        router.set_provider(Some(Box::new(CountingProvider {
            calls: calls.clone(),
        })));
        assert!(router.has_provider());
        assert!(
            router
                .record_in_game_ui(&packet, &snapshot, target(device))
                .is_ok()
        );
        assert_eq!(calls.load(Ordering::Relaxed), 1);
    }
}
