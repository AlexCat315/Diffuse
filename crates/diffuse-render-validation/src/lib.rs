//! Crate root. See MIGRATION.md §5.
pub mod native_pass_benchmark;
pub mod probes;
pub mod reference;
#[cfg(test)]
pub mod tests;

pub use native_pass_benchmark::{
    NativePassBenchmark, NativeValidationError, PassBenchmarkResult, PassParticleSimulationWork,
    PassParticleWork, PassTimingDistribution,
};
pub use probes::{
    animated_probe_scene::AnimatedProbeScene, grid_probe_scene::GridProbeScene,
    mesh_probe_scene::MeshProbeScene, particle_probe_scene::ParticleProbeScene,
    particle_simulation_probe_scene::ParticleSimulationProbeScene, pbr_probe_scene::PBRProbeScene,
    post_probe_scene::PostProbeScene, stylized_probe_scene::StylizedProbeScene,
};
pub use reference::{
    grid_image::{GridImage, GridImageDifference},
    scene_capture::SceneCapture,
};
