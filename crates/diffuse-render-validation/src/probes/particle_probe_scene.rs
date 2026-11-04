use super::post_probe_scene::PostProbeScene;
use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_render::{RenderDrawableSize, RenderPacket};
use diffuse_scene::particles::particle_types::ParticleBlendMode;
use diffuse_scene::rendering::render_scene::{RenderParticle, RenderParticleShape};

pub enum ParticleProbeScene {}
impl ParticleProbeScene {
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut packet = PostProbeScene::packet(size, frame);
        let phase = (frame % 120) as f32 * 0.015;
        packet.scene.particles = (0..2048)
            .map(|index| {
                let x = (index % 64) as f32 * 0.2 - 6.4;
                let z = (index / 64) as f32 * 0.24 - 3.8;
                RenderParticle::new(
                    Float3::new(
                        x + (phase + z).sin() * 0.2,
                        1.5 + (x + phase).sin() * 0.9,
                        z,
                    ),
                    0.13,
                    phase,
                    Float4::new(
                        0.5 + (index % 7) as f32 * 0.18,
                        0.2 + (index % 5) as f32 * 0.1,
                        0.8,
                        0.55,
                    ),
                    None,
                    Float4::new(0.0, 0.0, 1.0, 1.0),
                    if index % 5 == 0 {
                        Float3::new(0.4, 1.0, 0.0)
                    } else {
                        Float3::ZERO
                    },
                    2.0,
                    None,
                    None,
                    RenderParticleShape::SoftBillboard,
                    0.0,
                    0.0,
                    if (index / 128) % 2 == 0 {
                        ParticleBlendMode::Alpha
                    } else {
                        ParticleBlendMode::Additive
                    },
                    None,
                )
            })
            .collect();
        for index in 0..32 {
            packet.scene.particles.push(Self::ribbon(index));
        }
        packet
    }

    /// Shared by the two probes; every ribbon field matches their identical Swift literals.
    pub(super) fn ribbon(index: usize) -> RenderParticle {
        RenderParticle::new(
            Float3::new(index as f32 * 0.3 - 4.8, 3.2, 3.0),
            0.5,
            0.0,
            Float4::new(1.5, 0.5, 0.1, 0.7),
            Some(Float4::new(0.2, 0.5, 1.5, 0.0)),
            Float4::new(0.0, 0.0, 1.0, 1.0),
            Float3::new(1.0, 0.4, 0.0),
            2.0,
            Some(0.15),
            Some(0.02),
            RenderParticleShape::RibbonSegment,
            0.0,
            0.0,
            ParticleBlendMode::Additive,
            None,
        )
    }
}
