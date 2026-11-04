//! Crate root. See MIGRATION.md §5.
pub mod core;
pub mod native;
pub mod registries;
pub mod render_backend_resource_bundle;
pub mod support;
pub mod surface;

pub use core::frame::render_camera_matrices::{RenderCameraMatrices, RenderCameraProjectionMatrix};
pub use core::frame::render_frame_plan::{RenderFramePlan, RenderFramePlanner, RenderPassKind};
pub use core::frame::render_packet::{
    RenderDrawableSize, RenderPacket, RenderPacketConsumer, RenderSurfaceDescriptor,
};
pub use core::frame::render_uniforms::{
    BloomUniforms, PostFrameUniforms, SkyboxUniforms, SsaoUniforms, SsrUniforms,
    StylizedCharacterUniforms, TaaUniforms, TonemapUniforms,
};
pub use core::frame::viewport_target_allocation::ViewportTargetAllocation;
pub use core::frame::viewport_target_sizing::ViewportTargetSizing;
pub use core::lighting::environment_ibl::{MipLevel, StudioEnvironmentIBL};
pub use core::lighting::grid_plane::EditorGridPlane;
pub use core::lighting::grid_uniforms::EditorGridUniforms;
pub use core::lighting::post_effect_uniforms::PostEffectUniforms;
pub use core::lighting::shadow_atlas_plan::{ShadowAtlasLight, ShadowAtlasPlan};
pub use core::lighting::shadow_atlas_planner::{
    ShadowAtlasPlanner, shadow_atlas_capacity, shadow_atlas_grid_dimension,
};
pub use core::lighting::uniforms::{
    DEFAULT_SHADOW_MAP_RESOLUTION, MAX_SCENE_LIGHT_UNIFORM_COUNT, MAX_SHADOW_ATLAS_TILE_COUNT,
    MAX_SHADOWED_DIRECTIONAL_LIGHT_COUNT, SceneLightUniform, SceneLightUniforms,
    ShadowLightBinding, ShadowRenderUniforms, ShadowUniforms,
};
pub use core::mesh::deformable_mesh_vertex_stream::DeformableMeshVertexStream;
pub use core::mesh::deformable_upload_report::DeformableMeshUploadReport;
pub use core::mesh::mesh_instance_uniforms::MeshInstanceUniforms;
pub use core::mesh::mesh_visibility_plan::MeshVisibilityPlan;
pub use core::mesh::opaque_scene_fingerprint::OpaqueSceneFingerprint;
pub use core::mesh::resolved_mesh_material::ResolvedMeshMaterial;
pub use core::particles::gpu_particle_simulation_event_bridge::{
    GPUParticleSimulationEventRecordBridge, GPUParticleSimulationEventSnapshotBridge,
    GPUParticleSimulationEventTriggerBridge,
};
pub use core::particles::particle_gpu_data::{
    GPUParticleCullBatch, GPUParticleCullUniforms, GPUParticleIndirectDrawArgs,
    GPUParticleInstance, ParticleUniforms,
};
pub use core::particles::particle_instance_gpu_data::{
    GPUParticleAppearance, GPUParticleAppearanceData, GPUParticleCurveEncoding,
    GPUParticleCurveKeyframe, GPUParticleSimulationInstanceEncodeReport,
    GPUParticleSimulationInstanceUniforms, GPUParticleSimulationSortEncodeReport,
    GPUParticleSortBitonicUniforms, GPUParticleSortItem, GPUParticleSortPlan,
    GPUParticleSortPrepareUniforms, GPUParticleSortStage,
};
pub use core::particles::particle_simulation_gpu_data::{
    GPUParticleSimulationEvent, GPUParticleSimulationMetadata, GPUParticleSimulationState,
    GPUParticleSimulationUniforms, GPUParticleSpawnUniforms, GPUParticleStateMaintenanceUniforms,
};
pub use core::particles::simulation_report::GPUParticleSimulationEncodeReport;
pub use core::render_settings::{
    Backdrop, DebugViewMode, DirectionalLightSelection, PostProcessing, RenderSettings,
    RenderShadowSettings, Shading, Stylization, StylizedCharacterStyle, ViewportSettings,
    Visibility,
};
pub use core::render_stats::{
    GPUParticleSimulationEventRecord, GPUParticleSimulationEventSnapshot,
    GPUParticleSimulationEventTrigger, RenderFrameStats,
};
pub use core::render_temporal_state::{RenderFrameResourceVersion, RenderTemporalState};
