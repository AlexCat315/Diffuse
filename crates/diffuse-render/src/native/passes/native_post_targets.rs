//! Fullscreen post targets. Every texture is allocated only when a pass in the
//! assembled pipeline actually reads or writes it.

use cove_graphics::rhi::{
    Device, RhiResult, Texture, TextureDescriptor, TextureFormat, TextureUsage,
};

use crate::core::frame::render_packet::RenderDrawableSize;
use crate::core::render_settings::RenderSettings;

/// Which post targets a frame needs, derived solely from the capability
/// switches. The opaque-cache snapshot is excluded: it is allocated on demand
/// when the scene first becomes stable, so always-moving scenes never pay for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativePostRequirements {
    /// Number of fullscreen effects that ping-pong through the HDR color
    /// targets (ink paper, SSAO, SSR, TAA, Bloom). 0 → none, 1 → target `a`,
    /// ≥2 → `a` + `b`.
    pub ping_pong_effects: usize,
    pub needs_history: bool,
    pub needs_ldr: bool,
}

impl NativePostRequirements {
    pub fn make(settings: &RenderSettings) -> Self {
        let ping_pong = usize::from(settings.stylization.enabled)
            + usize::from(settings.post_processing.ssao)
            + usize::from(settings.post_processing.ssr)
            + usize::from(settings.post_processing.taa)
            + usize::from(settings.post_processing.bloom);
        NativePostRequirements {
            ping_pong_effects: ping_pong,
            needs_history: settings.post_processing.taa,
            needs_ldr: settings.post_processing.fxaa,
        }
    }
}

#[derive(Clone, Debug)]
pub struct NativePostTargets {
    /// Matches the scene color/depth capacity, including history and snapshot.
    pub size: RenderDrawableSize,
    pub requirements: NativePostRequirements,
    pub a: Option<Texture>,
    pub b: Option<Texture>,
    pub history: Option<Texture>,
    pub ldr: Option<Texture>,
    /// Opaque-cache storage, allocated lazily on the first stable capture.
    pub snapshot: Option<Texture>,
}

impl NativePostTargets {
    pub fn textures(&self) -> Vec<Texture> {
        [self.a, self.b, self.history, self.ldr, self.snapshot]
            .into_iter()
            .flatten()
            .collect()
    }

    /// Ping-pong target following `texture`. The first effect leaves the scene
    /// HDR target for `a`; subsequent effects alternate between `a` and `b`.
    pub fn next(&self, texture: Texture) -> Texture {
        if self.a == Some(texture) {
            return self.b.unwrap_or_else(|| self.a.expect("checked above"));
        }
        self.a.expect("ping-pong requires target a")
    }

    /// Allocates the opaque-cache snapshot the first time a stable frame is
    /// captured.
    pub fn ensure_snapshot(&mut self, device: &Device) -> RhiResult<Texture> {
        if let Some(snapshot) = self.snapshot {
            return Ok(snapshot);
        }
        let texture = device.make_texture(
            TextureDescriptor::new(
                self.size.width as usize,
                self.size.height as usize,
                TextureFormat::Rgba16Float,
                TextureUsage::COLOR_TARGET
                    | TextureUsage::SAMPLED
                    | TextureUsage::TRANSFER_SOURCE
                    | TextureUsage::TRANSFER_DESTINATION,
            )
            .with_label("native-post-snapshot"),
        )?;
        self.snapshot = Some(texture);
        Ok(texture)
    }

    pub fn destroy(&self, device: &Device) {
        for texture in self.textures() {
            device.destroy_texture(texture);
        }
    }

    pub fn make(
        device: &Device,
        size: RenderDrawableSize,
        requirements: NativePostRequirements,
    ) -> RhiResult<Self> {
        let mut created: Vec<Texture> = Vec::new();
        let make_hdr_color =
            |label: &'static str, created: &mut Vec<Texture>| -> RhiResult<Texture> {
                let texture = device.make_texture(
                    TextureDescriptor::new(
                        size.width as usize,
                        size.height as usize,
                        TextureFormat::Rgba16Float,
                        TextureUsage::COLOR_TARGET
                            | TextureUsage::SAMPLED
                            | TextureUsage::TRANSFER_SOURCE
                            | TextureUsage::TRANSFER_DESTINATION,
                    )
                    .with_label(label),
                )?;
                created.push(texture);
                Ok(texture)
            };
        let make_ldr_color =
            |label: &'static str, created: &mut Vec<Texture>| -> RhiResult<Texture> {
                let texture = device.make_texture(
                    TextureDescriptor::new(
                        size.width as usize,
                        size.height as usize,
                        TextureFormat::Bgra8Unorm,
                        TextureUsage::COLOR_TARGET
                            | TextureUsage::SAMPLED
                            | TextureUsage::TRANSFER_SOURCE
                            | TextureUsage::TRANSFER_DESTINATION,
                    )
                    .with_label(label),
                )?;
                created.push(texture);
                Ok(texture)
            };
        let result = (|| {
            let a = if requirements.ping_pong_effects >= 1 {
                Some(make_hdr_color("native-post-a", &mut created)?)
            } else {
                None
            };
            let b = if requirements.ping_pong_effects >= 2 {
                Some(make_hdr_color("native-post-b", &mut created)?)
            } else {
                None
            };
            let history = if requirements.needs_history {
                Some(make_hdr_color("native-post-history", &mut created)?)
            } else {
                None
            };
            let ldr = if requirements.needs_ldr {
                Some(make_ldr_color("native-post-ldr", &mut created)?)
            } else {
                None
            };
            Ok(NativePostTargets {
                size,
                requirements,
                a,
                b,
                history,
                ldr,
                snapshot: None,
            })
        })();
        match result {
            Ok(targets) => Ok(targets),
            Err(error) => {
                for texture in created {
                    device.destroy_texture(texture);
                }
                Err(error)
            }
        }
    }
}
