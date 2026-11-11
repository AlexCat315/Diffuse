//! Scene renderer recorded entirely through NativeRHI. The initial migration
//! supports opaque/masked/transparent meshes and animation, PBR lighting,
//! directional shadows, HDR sky/tonemap, stylized materials/outline/paper,
//! post-processing effects, temporal history/cache, the grid, CPU-authored
//! particle draws and resident GPU particle physics/events, GPU sorting,
//! simulated-particle instance conversion and the installed CoveUI HUD provider
//! after scene post-processing.
//!
//! RenderThread owns all mutable renderer state; the Swift `final class` maps
//! to an owned struct whose frame-state fields live behind a `Mutex` so the
//! read accessors match Swift's nonisolated properties.

use std::sync::Arc;

use std::collections::BTreeMap;
use std::sync::Mutex;

use cove_graphics::rhi::{
    ColorLoadAction, CommandBuffer, DepthLoadAction, Device, RenderColorTarget, RenderDepthTarget,
    ResourcePreparationContext, RhiError, RhiResult, Texture, TextureResource,
};
use cove_logging::{Level, LogEvent};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::Float4;
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;

use crate::core::frame::render_frame_plan::{RenderFramePlanner, RenderPassKind};
use crate::core::frame::render_packet::{
    RenderDrawableSize, RenderPacket, RenderPacketConsumer, RenderSurfaceDescriptor,
};
use crate::core::frame::render_uniforms::StylizedCharacterUniforms;
use crate::core::frame::viewport_target_sizing::ViewportTargetSizing;
use crate::core::lighting::post_effect_uniforms::PostEffectUniforms;
use crate::core::lighting::shadow_atlas_planner::ShadowAtlasPlanner;
use crate::core::render_settings::{DebugViewMode, RenderSettings};
use crate::core::render_stats::{GPUParticleSimulationEventSnapshot, RenderFrameStats};
use crate::core::render_temporal_state::{RenderFrameResourceVersion, RenderTemporalState};
use crate::native::lighting::native_hdr_passes::NativeHDRPasses;
use crate::native::lighting::native_lighting_resources::NativeLightingResources;
use crate::native::lighting::native_shadow_pass::NativeShadowPass;
use crate::native::mesh::native_deformable_meshes::NativeDeformableMeshes;
use crate::native::mesh::native_mesh_pass::{NativeMeshPass, NativeMeshPassKind};
use crate::native::mesh::native_mesh_store::NativeMeshStore;
use crate::native::mesh::native_skin_bindings::NativeSkinBindings;
use crate::native::particles::native_particle_pass::NativeParticlePass;
use crate::native::particles::native_particle_simulation::NativeParticleSimulation;
use crate::native::passes::native_editor_passes::NativeEditorPasses;
use crate::native::passes::native_post_passes::NativePostPasses;
use crate::native::passes::native_post_targets::NativePostRequirements;
use crate::native::targets::native_packet_validation::NativePacketValidation;
use crate::native::targets::native_render_targets::NativeRenderTargets;
use crate::native::targets::native_viewport_mip_chain::NativeViewportMipChain;
use crate::native::targets::native_window_target::NativeWindowTarget;
use crate::support::log;
use crate::surface::in_game_ui_providing::{InGameUIProviding, NativeInGameUITarget};
use crate::surface::viewport_surface::{
    ViewportSamplingRegion, ViewportSurfacePublication, ViewportSurfaceState,
};

/// Swift's `ResourcePreparationContext` step count:
/// `device.prepareResources(label: "Preparing shaders", totalSteps: 8, ...)`.
pub const PREPARATION_TOTAL_STEPS: usize = 8;

struct RendererFrameState {
    frame_state: RenderTemporalState,
    last_frame_stats: RenderFrameStats,
    last_error: Option<String>,
}

impl RendererFrameState {
    fn new() -> Self {
        RendererFrameState {
            frame_state: RenderTemporalState::new(),
            last_frame_stats: RenderFrameStats::untouched(),
            last_error: None,
        }
    }
}

pub struct NativeRenderer {
    pub device: Arc<Device>,
    in_game_ui: Option<Box<dyn InGameUIProviding>>,
    meshes: NativeMeshStore,
    mesh_pass: NativeMeshPass,
    deformables: NativeDeformableMeshes,
    lighting: NativeLightingResources,
    shadows: NativeShadowPass,
    hdr_passes: NativeHDRPasses,
    editor: NativeEditorPasses,
    post: NativePostPasses,
    particles: NativeParticlePass,
    pub particle_simulation: NativeParticleSimulation,
    state: Mutex<RendererFrameState>,
    window_target: Option<NativeWindowTarget>,
    targets: Mutex<Option<NativeRenderTargets>>,
    viewport_mips: Mutex<Option<NativeViewportMipChain>>,
    viewport_publication: Mutex<ViewportSurfacePublication>,
}

// Keep the Swift `defer { device.endFrame() }` on every return path.
struct FrameEnd(Arc<Device>);
impl Drop for FrameEnd {
    fn drop(&mut self) {
        self.0.end_frame();
    }
}

impl Drop for NativeRenderer {
    fn drop(&mut self) {
        let _ = self.device.with_frame_session(|| {
            self.particle_simulation.destroy();
            self.particles.destroy();
            self.post.destroy();
            self.editor.geometry.destroy();
            self.editor.grid.destroy();
            self.hdr_passes.destroy();
            self.shadows.destroy();
            self.lighting.destroy();
            self.deformables.destroy();
            self.mesh_pass.destroy();
            self.meshes.destroy();
            Ok(())
        });
    }
}

impl NativeRenderer {
    /// Swift's `init(device:surface:assets:inGameUI:preparation:initialSettings:
    /// particleWorkgroupSizes:)` with `preparation == nil`.
    pub fn new(
        device: &Arc<Device>,
        surface: Option<RenderSurfaceDescriptor>,
        assets: &'static AssetRegistry,
        in_game_ui: Option<Box<dyn InGameUIProviding>>,
        initial_settings: &RenderSettings,
        particle_workgroup_sizes: &[usize],
    ) -> RhiResult<Self> {
        Self::build(
            device,
            surface,
            assets,
            in_game_ui,
            initial_settings,
            particle_workgroup_sizes,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn build(
        device: &Arc<Device>,
        surface: Option<RenderSurfaceDescriptor>,
        assets: &'static AssetRegistry,
        in_game_ui: Option<Box<dyn InGameUIProviding>>,
        initial_settings: &RenderSettings,
        particle_workgroup_sizes: &[usize],
        preparation: Option<&ResourcePreparationContext>,
    ) -> RhiResult<Self> {
        let window_target = surface.map(|surface| NativeWindowTarget::new(device.clone(), surface));
        let meshes = renderer_preparation_step(preparation, "Meshes", || {
            NativeMeshStore::new(device, assets)
        })?;
        let mesh_pass =
            renderer_preparation_step(preparation, "Materials", || -> RhiResult<NativeMeshPass> {
                let mut pass = NativeMeshPass::new(device)?;
                if preparation.is_some() {
                    pass.prewarm(initial_settings)?;
                }
                Ok(pass)
            })
            .inspect_err(|_| meshes.destroy())?;
        let deformables = NativeDeformableMeshes::new(device);
        let lighting = renderer_preparation_step(preparation, "Lighting", || {
            NativeLightingResources::new(device)
        })
        .inspect_err(|_| {
            mesh_pass.destroy();
            meshes.destroy();
        })?;
        let shadows =
            renderer_preparation_step(preparation, "Shadows", || NativeShadowPass::new(device))
                .inspect_err(|_| {
                    lighting.destroy();
                    mesh_pass.destroy();
                    meshes.destroy();
                })?;
        let hdr_passes =
            renderer_preparation_step(preparation, "HDR", || NativeHDRPasses::new(device))
                .inspect_err(|_| {
                    shadows.destroy();
                    lighting.destroy();
                    mesh_pass.destroy();
                    meshes.destroy();
                })?;
        let editor =
            renderer_preparation_step(preparation, "Grid", || NativeEditorPasses::new(device))
                .inspect_err(|_| {
                    hdr_passes.destroy();
                    shadows.destroy();
                    lighting.destroy();
                    mesh_pass.destroy();
                    meshes.destroy();
                })?;
        let post = renderer_preparation_step(
            preparation,
            "Post-processing",
            || -> RhiResult<NativePostPasses> {
                let mut passes = NativePostPasses::new(device)?;
                if preparation.is_some() {
                    passes.prewarm(initial_settings)?;
                }
                Ok(passes)
            },
        )
        .inspect_err(|_| {
            editor.grid.destroy();
            editor.geometry.destroy();
            hdr_passes.destroy();
            shadows.destroy();
            lighting.destroy();
            mesh_pass.destroy();
            meshes.destroy();
        })?;
        let particles = renderer_preparation_step(
            preparation,
            "Particles",
            || -> RhiResult<(NativeParticlePass, NativeParticleSimulation)> {
                let mut pass = NativeParticlePass::new(device)?;
                let mut simulation = NativeParticleSimulation::new(device);
                if preparation.is_some() {
                    pass.prewarm(initial_settings.shading.pbr)?;
                    simulation.prewarm(particle_workgroup_sizes)?;
                }
                Ok((pass, simulation))
            },
        )
        .inspect_err(|_| {
            post.destroy();
            editor.grid.destroy();
            editor.geometry.destroy();
            hdr_passes.destroy();
            shadows.destroy();
            lighting.destroy();
            mesh_pass.destroy();
            meshes.destroy();
        })?;
        Ok(NativeRenderer {
            device: device.clone(),
            in_game_ui,
            meshes,
            mesh_pass,
            deformables,
            lighting,
            shadows,
            hdr_passes,
            editor,
            post,
            particles: particles.0,
            particle_simulation: particles.1,
            state: Mutex::new(RendererFrameState::new()),
            window_target,
            targets: Mutex::new(None),
            viewport_mips: Mutex::new(None),
            viewport_publication: Mutex::new(ViewportSurfacePublication::default()),
        })
    }

    /// Swift's `static func prepared(...)` — the preparation-context path.
    /// Rust has no `async`, so this runs synchronously on the calling thread.
    #[allow(clippy::too_many_arguments)]
    pub fn prepared(
        device: &Arc<Device>,
        surface: Option<RenderSurfaceDescriptor>,
        assets: &'static AssetRegistry,
        in_game_ui: Option<Box<dyn InGameUIProviding>>,
        initial_settings: &RenderSettings,
        particle_workgroup_sizes: &[usize],
        on_progress: impl Fn(cove_graphics::rhi::ResourcePreparationProgress) + Send + Sync + 'static,
    ) -> RhiResult<Self> {
        device.prepare_resources(
            "Preparing shaders",
            Some(PREPARATION_TOTAL_STEPS),
            on_progress,
            |context| {
                Self::build(
                    device,
                    surface,
                    assets,
                    in_game_ui,
                    initial_settings,
                    particle_workgroup_sizes,
                    Some(context),
                )
            },
        )
    }

    pub fn initialize(&self) {
        log::renderer().log(&LogEvent::new(
            Level::Info,
            format!("NativeRenderer ready ({})", self.device.device_name()),
        ));
    }

    pub fn current_frame_stats(&self) -> RenderFrameStats {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .last_frame_stats
            .clone()
    }

    pub fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        self.viewport_publication
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .state
            .clone()
    }

    pub fn drain_gpu_particle_simulation_event_snapshots(
        &mut self,
        max_snapshots: usize,
    ) -> RhiResult<Vec<GPUParticleSimulationEventSnapshot>> {
        self.device
            .with_frame_session(|| self.particle_simulation.drain(max_snapshots))
    }

    /// Borrowed handle for immediate recording/readback. Retain a viewport
    /// surface's owned image when the output must survive target replacement.
    pub fn color_texture(&self) -> Option<Texture> {
        self.targets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .and_then(|targets| targets.color.as_ref().map(|color| color.texture()))
    }

    pub fn resident_mesh_count(&self) -> usize {
        self.meshes.resident_count()
    }

    pub fn render(&mut self, packet: &RenderPacket) {
        if let Err(error) = self.render_checked(packet) {
            {
                let mut state = self
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                state.last_error = Some(error.to_string());
            }
            log::renderer().log(&LogEvent::new(
                Level::Error,
                format!("native scene render failed: {error}"),
            ));
        }
    }

    pub fn render_checked(&mut self, packet: &RenderPacket) -> RhiResult<()> {
        self.device
            .clone()
            .with_frame_session(|| self.render_frame(packet))
    }

    fn render_frame(&mut self, packet: &RenderPacket) -> RhiResult<()> {
        let start = std::time::Instant::now();
        let matrices = NativePacketValidation::validate(packet)?;
        let ui_provider = self.in_game_ui.as_deref();
        if !packet.in_game_canvas.commands.is_empty() && ui_provider.is_none() {
            return Err(RhiError::unsupported_feature(
                "script HUD requires an installed in-game UI provider",
            ));
        }
        self.meshes.synchronize()?;
        let hdr = packet.render_settings.shading.pbr;
        if hdr || packet.render_settings.shading.debug_view_mode == DebugViewMode::Shaded {
            self.lighting.ensure_environment()?;
        }
        let mesh_revision = self.meshes.revision;
        let post_revision = self.post.revision;
        let shadow_plan = ShadowAtlasPlanner::make_shadow_atlas_plan(
            &packet.scene,
            packet.drawable_size,
            hdr,
            &packet.render_settings.shadows,
            &packet.joint_palette_map,
            &|mesh_index| {
                self.meshes
                    .mesh(mesh_index)
                    .map(|mesh| mesh.geometry.bounds)
            },
        );
        self.shadows.ensure_targets(&shadow_plan)?;
        self.ensure_targets(packet.drawable_size, hdr)?;
        let targets_guard = self
            .targets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(targets) = targets_guard.as_ref() else {
            return Err(RhiError::OutOfMemory);
        };
        // Post targets back the HDR ping-pong chain and, for an LDR scene, the
        // FXAA input. They are allocated whenever the assembled pipeline needs
        // them, independent of whether PBR is enabled.
        if hdr || packet.render_settings.post_processing.fxaa {
            self.post.ensure_targets(
                targets.size,
                NativePostRequirements::make(&packet.render_settings),
            )?;
        }
        let mut next_frame = {
            let state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.frame_state.clone()
        };
        next_frame.prepare(
            packet,
            RenderFrameResourceVersion::new(mesh_revision, post_revision, packet.drawable_size),
            hdr,
        );
        self.device.begin_frame()?;
        let _frame = FrameEnd(self.device.clone());
        let has_depth = packet.render_settings.shading.depth_prepass;
        let mut commands = CommandBuffer::new();
        let simulation_start = std::time::Instant::now();
        let simulation = self.particle_simulation.prepare(
            &packet.scene,
            packet.delta_time as f32,
            packet.simulation_time_seconds as f32,
            &mut commands,
        )?;
        let simulation_time = simulation_start.elapsed();
        let deformable_start = std::time::Instant::now();
        let dynamic = self
            .deformables
            .prepare(&packet.scene.deformable_meshes, &mut commands)?;
        let deformable_time = deformable_start.elapsed();
        let dynamic_geometries = dynamic.geometries();
        let dynamic_report = dynamic.report;
        let skin = NativeSkinBindings::new(packet, &self.device)?;
        let light_bindings = self.lighting.prepare(
            packet,
            &shadow_plan,
            self.shadows.atlas(),
            self.meshes.fallbacks[0],
        )?;
        let shadow_tiles = self.shadows.prepare(
            packet,
            &self.meshes,
            &shadow_plan,
            &skin,
            &dynamic_geometries,
        )?;
        let prepared = self.mesh_pass.prepare(
            packet,
            &self.meshes,
            &matrices,
            has_depth,
            hdr,
            &light_bindings,
            &skin,
            &dynamic_geometries,
        )?;
        let particle_frame = self.particles.prepare(
            &packet.scene,
            &matrices,
            hdr,
            simulation.render.as_ref(),
            &mut commands,
        )?;
        let opaque_draws: Vec<_> = prepared
            .0
            .iter()
            .filter(|draw| draw.batch.key.mode != MaterialAlphaMode::Blend)
            .collect();
        let mut transparent_draws: Vec<_> = prepared
            .0
            .iter()
            .filter(|draw| draw.batch.key.mode == MaterialAlphaMode::Blend)
            .collect();
        transparent_draws.sort_by(|lhs, rhs| {
            rhs.batch
                .distance
                .partial_cmp(&lhs.batch.distance)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let image = self
            .window_target
            .as_ref()
            .map(|target| target.acquire())
            .transpose()?;
        let Some(color) = image
            .as_ref()
            .map(|image| image.texture)
            .or_else(|| targets.color.as_ref().map(|color| color.texture()))
        else {
            drop(targets_guard);
            return Err(RhiError::SwapchainAcquireFailed(
                "no scene color target".into(),
            ));
        };
        let prepare_end = start.elapsed();
        let mut pass_times: BTreeMap<RenderPassKind, u64> = BTreeMap::new();
        let mut pass_draws: BTreeMap<RenderPassKind, i64> = BTreeMap::new();
        let mut active: Vec<RenderPassKind> = Vec::new();
        // An LDR scene with FXAA renders into the LDR target so FXAA can read
        // it and write the final color (a pass cannot read and write the same
        // texture). Otherwise the scene renders straight into the color target.
        let mut current = targets
            .hdr
            .as_ref()
            .map(|hdr| hdr.texture())
            .or(if packet.render_settings.post_processing.fxaa {
                self.post.targets().and_then(|targets| targets.ldr)
            } else {
                None
            })
            .unwrap_or(color);
        let mut bloom: Option<Texture> = None;
        let planned = RenderFramePlanner::make_plan(&packet.render_settings);
        let passes =
            RenderFramePlanner::motion_refined_passes(&planned.passes, next_frame.moving());
        for kind in passes {
            if next_frame.cache_hit() && kind.is_opaque_pass() {
                continue;
            }
            let before = std::time::Instant::now();
            let mut draws = 1i64;
            match kind {
                RenderPassKind::DepthPrepass => {
                    let owned: Vec<_> = opaque_draws.iter().map(|draw| (*draw).clone()).collect();
                    self.mesh_pass.encode(
                        &owned,
                        packet.drawable_size,
                        None,
                        RenderDepthTarget {
                            texture: targets.depth.texture(),
                            load_action: DepthLoadAction::Clear(1.0),
                            store: true,
                        },
                        NativeMeshPassKind::Depth,
                        &mut commands,
                    );
                    draws = opaque_draws.len() as i64;
                }
                RenderPassKind::ShadowPass => {
                    if shadow_tiles.is_empty() {
                        continue;
                    }
                    self.shadows
                        .encode(&shadow_tiles, &shadow_plan, &mut commands);
                    draws = shadow_tiles
                        .iter()
                        .map(|tile| tile.draws.len())
                        .sum::<usize>() as i64;
                }
                RenderPassKind::Skybox => {
                    self.hdr_passes.encode_sky(
                        packet,
                        &matrices,
                        current,
                        targets.depth.texture(),
                        &mut commands,
                    )?;
                }
                RenderPassKind::BasePass => {
                    let owned: Vec<_> = opaque_draws.iter().map(|draw| (*draw).clone()).collect();
                    self.mesh_pass.encode(
                        &owned,
                        packet.drawable_size,
                        Some(RenderColorTarget {
                            texture: current,
                            load_action: if hdr {
                                ColorLoadAction::Load
                            } else {
                                ColorLoadAction::Clear([0.05, 0.06, 0.08, 1.0])
                            },
                            store: true,
                            resolve_texture: None,
                        }),
                        RenderDepthTarget {
                            texture: targets.depth.texture(),
                            load_action: if has_depth {
                                DepthLoadAction::Load
                            } else {
                                DepthLoadAction::Clear(1.0)
                            },
                            store: true,
                        },
                        NativeMeshPassKind::Color,
                        &mut commands,
                    );
                    draws = opaque_draws.len() as i64;
                }
                RenderPassKind::Ssao | RenderPassKind::Ssr => {
                    let Some(resources) = self.post.targets() else {
                        drop(targets_guard);
                        return Err(RhiError::OutOfMemory);
                    };
                    let output = resources.next(current);
                    if kind == RenderPassKind::Ssao {
                        self.post.encode(
                            kind,
                            current,
                            targets.depth.texture(),
                            output,
                            PostEffectUniforms::ssao(matrices.projection, packet.drawable_size),
                            packet.drawable_size,
                            &mut commands,
                        )?;
                    } else {
                        self.post.encode(
                            kind,
                            current,
                            targets.depth.texture(),
                            output,
                            PostEffectUniforms::ssr(matrices.projection, packet.drawable_size),
                            packet.drawable_size,
                            &mut commands,
                        )?;
                    }
                    current = output;
                }
                RenderPassKind::EditorGrid => {
                    if hdr {
                        self.hdr_passes.encode_grid(
                            packet,
                            current,
                            targets.depth.texture(),
                            &mut commands,
                        )?;
                    } else {
                        self.editor.grid.encode(
                            packet,
                            RenderColorTarget {
                                texture: current,
                                load_action: ColorLoadAction::Load,
                                store: true,
                                resolve_texture: None,
                            },
                            RenderDepthTarget {
                                texture: targets.depth.texture(),
                                load_action: DepthLoadAction::Load,
                                store: true,
                            },
                            &mut commands,
                        )?;
                    }
                }
                RenderPassKind::Taa => {
                    let Some(resources) = self.post.targets() else {
                        drop(targets_guard);
                        return Err(RhiError::OutOfMemory);
                    };
                    let Some(history) = resources.history else {
                        drop(targets_guard);
                        return Err(RhiError::OutOfMemory);
                    };
                    let output = resources.next(current);
                    self.post.encode(
                        kind,
                        current,
                        history,
                        output,
                        PostEffectUniforms::taa(resources.size, next_frame.history_valid),
                        packet.drawable_size,
                        &mut commands,
                    )?;
                    let size = packet.drawable_size;
                    commands.copy_pass(|copy| {
                        copy.copy_texture(output, history, size.width as i64, size.height as i64);
                    });
                    next_frame.history_valid = true;
                    current = output;
                }
                RenderPassKind::TransparentMeshes => {
                    if hdr && let Some(scene_hdr) = targets.hdr.as_ref().map(|hdr| hdr.texture()) {
                        if next_frame.cache_hit() {
                            let Some(snapshot) = self.post.snapshot() else {
                                drop(targets_guard);
                                return Err(RhiError::OutOfMemory);
                            };
                            let size = packet.drawable_size;
                            commands.copy_pass(|copy| {
                                copy.copy_texture(
                                    snapshot,
                                    scene_hdr,
                                    size.width as i64,
                                    size.height as i64,
                                );
                            });
                            current = scene_hdr;
                        } else if next_frame.can_capture(&packet.render_settings) {
                            let snapshot = self.post.ensure_snapshot()?;
                            let size = packet.drawable_size;
                            commands.copy_pass(|copy| {
                                copy.copy_texture(
                                    current,
                                    snapshot,
                                    size.width as i64,
                                    size.height as i64,
                                );
                            });
                            next_frame.snapshot_valid = true;
                        }
                    }
                    if transparent_draws.is_empty() {
                        continue;
                    }
                    let owned: Vec<_> = transparent_draws
                        .iter()
                        .map(|draw| (*draw).clone())
                        .collect();
                    self.mesh_pass.encode(
                        &owned,
                        packet.drawable_size,
                        Some(RenderColorTarget {
                            texture: current,
                            load_action: ColorLoadAction::Load,
                            store: true,
                            resolve_texture: None,
                        }),
                        RenderDepthTarget {
                            texture: targets.depth.texture(),
                            load_action: DepthLoadAction::Load,
                            store: true,
                        },
                        NativeMeshPassKind::Color,
                        &mut commands,
                    );
                    draws = transparent_draws.len() as i64;
                }
                RenderPassKind::Bloom => {
                    let Some(resources) = self.post.targets() else {
                        drop(targets_guard);
                        return Err(RhiError::OutOfMemory);
                    };
                    let output = resources.next(current);
                    self.post.encode(
                        kind,
                        current,
                        current,
                        output,
                        PostEffectUniforms::bloom(resources.size),
                        packet.drawable_size,
                        &mut commands,
                    )?;
                    bloom = Some(output);
                }
                RenderPassKind::Tonemap => {
                    let output = if packet.render_settings.post_processing.fxaa {
                        self.post
                            .targets()
                            .and_then(|targets| targets.ldr)
                            .unwrap_or(color)
                    } else {
                        color
                    };
                    self.hdr_passes.encode_tonemap(
                        packet.drawable_size,
                        targets.size,
                        current,
                        output,
                        bloom,
                        &mut commands,
                    )?;
                }
                RenderPassKind::Fxaa => {
                    let Some(input) = self.post.targets().and_then(|targets| targets.ldr) else {
                        drop(targets_guard);
                        return Err(RhiError::OutOfMemory);
                    };
                    self.post.encode(
                        kind,
                        input,
                        input,
                        color,
                        Float4::new(
                            1.0 / targets.size.width as f32,
                            1.0 / targets.size.height as f32,
                            0.0,
                            0.0,
                        ),
                        packet.drawable_size,
                        &mut commands,
                    )?;
                }
                RenderPassKind::Particles => {
                    let Some(particle_frame) = &particle_frame else {
                        continue;
                    };
                    self.particles.encode(
                        particle_frame,
                        packet.drawable_size,
                        current,
                        targets.depth.texture(),
                        &mut commands,
                    );
                    draws = particle_frame.draws.len() as i64;
                }
                RenderPassKind::ViewportResolve
                | RenderPassKind::InGameUI
                | RenderPassKind::EditorGeometry => continue,
                RenderPassKind::Outline => {
                    let outlines: Vec<_> = opaque_draws
                        .iter()
                        .filter(|draw| draw.outline_pipeline.is_some())
                        .map(|draw| (*draw).clone())
                        .collect();
                    self.mesh_pass.encode(
                        &outlines,
                        packet.drawable_size,
                        Some(RenderColorTarget {
                            texture: current,
                            load_action: ColorLoadAction::Load,
                            store: true,
                            resolve_texture: None,
                        }),
                        RenderDepthTarget {
                            texture: targets.depth.texture(),
                            load_action: DepthLoadAction::Load,
                            store: true,
                        },
                        NativeMeshPassKind::Outline,
                        &mut commands,
                    );
                    draws = outlines.len() as i64;
                }
                RenderPassKind::InkPaperPost => {
                    if !hdr {
                        continue;
                    }
                    let Some(resources) = self.post.targets() else {
                        continue;
                    };
                    let output = resources.next(current);
                    self.post.encode(
                        kind,
                        current,
                        current,
                        output,
                        StylizedCharacterUniforms::from_style(
                            &packet.render_settings.stylization.style,
                        ),
                        packet.drawable_size,
                        &mut commands,
                    )?;
                    current = output;
                }
            }
            pass_times.insert(kind, before.elapsed().as_nanos() as u64);
            pass_draws.insert(kind, draws);
            active.push(kind);
        }
        if !packet.scene.geometry_overlays.is_empty() {
            let before = std::time::Instant::now();
            let draws = self.editor.geometry.encode(
                packet,
                color,
                targets.depth.texture(),
                &mut commands,
            )?;
            if draws > 0 {
                active.push(RenderPassKind::EditorGeometry);
                pass_draws.insert(RenderPassKind::EditorGeometry, draws as i64);
                pass_times.insert(
                    RenderPassKind::EditorGeometry,
                    before.elapsed().as_nanos() as u64,
                );
            }
        }
        let ui_start = std::time::Instant::now();
        let ui = self.encode_in_game_ui(packet, ui_provider, color, &mut commands)?;
        if let Some(ui) = &ui {
            active.push(RenderPassKind::InGameUI);
            pass_times.insert(
                RenderPassKind::InGameUI,
                ui_start.elapsed().as_nanos() as u64,
            );
            pass_draws.insert(RenderPassKind::InGameUI, ui.draw_call_count as i64);
        }
        let mut mipmaps: Vec<Arc<TextureResource>> = Vec::new();
        if packet.mipmapped_viewport_output {
            if let Some(output) = targets.color.as_ref() {
                let mut mips_guard = self
                    .viewport_mips
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if mips_guard.is_none() {
                    *mips_guard = Some(NativeViewportMipChain::new(&self.device)?);
                }
                let Some(mips) = mips_guard.as_mut() else {
                    drop(targets_guard);
                    return Err(RhiError::OutOfMemory);
                };
                mipmaps = mips.record(output, packet.drawable_size, &mut commands)?;
            }
        } else {
            self.viewport_mips
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take();
        }
        let encoded = start.elapsed();
        self.device.submit(
            &commands,
            cove_graphics::rhi::QueueClass::Graphics,
            &[],
            &[],
            None,
        )?;
        if let Some(mut ui) = ui {
            ui.did_submit();
        }
        self.deformables.commit(dynamic);
        self.particle_simulation.commit(simulation);
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.frame_state = next_frame;
        }
        let capacity = targets.size;
        let published_color = targets.color.clone();
        drop(targets_guard);
        if let Some(output) = published_color {
            self.viewport_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .publish(
                    output,
                    mipmaps,
                    ViewportSamplingRegion::new(packet.drawable_size, capacity),
                );
        } else {
            self.viewport_publication
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear();
        }
        if let Some(image) = image {
            self.device.present(image)?;
        }

        drop(_frame);
        let end = start.elapsed();
        let simulation_report = self.particle_simulation.last_report();
        let mut stats = RenderFrameStats::untouched();
        stats.frame_index = packet.frame_index;
        stats.pass_count = active.len() as i64;
        stats.active_passes = active;
        stats.draw_call_count = pass_draws.values().sum();
        stats.pass_draw_call_counts = pass_draws.clone();
        stats.pass_encode_ns = pass_times.clone();
        stats.cpu_prepare_ns = prepare_end.as_nanos() as u64;
        stats.cpu_encode_ns = (encoded - prepare_end).as_nanos() as u64;
        stats.cpu_post_process_encode_ns = [
            RenderPassKind::InkPaperPost,
            RenderPassKind::Ssao,
            RenderPassKind::Ssr,
            RenderPassKind::Taa,
            RenderPassKind::Bloom,
            RenderPassKind::Tonemap,
            RenderPassKind::Fxaa,
        ]
        .into_iter()
        .map(|kind| pass_times.get(&kind).copied().unwrap_or(0))
        .sum();
        stats.cpu_submit_ns = (end - encoded).as_nanos() as u64;
        stats.cpu_frame_total_ns = end.as_nanos() as u64;
        stats.visible_mesh_instance_count = prepared.1.visible_indices.len() as i64;
        stats.culled_mesh_instance_count = prepared.1.culled_count as i64;
        stats.lod_mesh_instance_count = prepared.1.lod_count as i64;
        stats.shadowed_light_count = shadow_plan.shadowed_light_count() as i64;
        stats.shadow_tile_count = shadow_plan.shadow_tile_count() as i64;
        stats.shadow_cascade_count = shadow_plan.cascade_count as i64;
        stats.shadow_map_resolution = shadow_plan.tile_size;
        stats.shadow_atlas_resolution = shadow_plan.atlas_size;
        stats.mesh_batch_count = prepared.0.len() as i64;
        stats.instanced_mesh_batch_count = prepared
            .0
            .iter()
            .filter(|draw| draw.batch.uniforms.len() > 1)
            .count() as i64;
        stats.submitted_mesh_triangle_count = prepared
            .0
            .iter()
            .map(|draw| draw.batch.key.index_count / 3 * draw.batch.uniforms.len() as i64)
            .sum();
        stats.deformable_mesh_count = dynamic_report.mesh_count as i64;
        stats.deformable_vertex_count = dynamic_report.vertex_count as i64;
        stats.deformable_triangle_count = dynamic_report.triangle_count as i64;
        stats.deformable_rejected_mesh_count = dynamic_report.rejected_mesh_count as i64;
        stats.deformable_uploaded_bytes = dynamic_report.uploaded_bytes;
        stats.deformable_upload_ns = deformable_time.as_nanos() as u64;
        stats.gpu_particle_cull_batch_count = particle_frame
            .as_ref()
            .map_or(0, |frame| frame.draws.len() as i64);
        stats.gpu_particle_cull_candidate_count = particle_frame
            .as_ref()
            .map_or(0, |frame| frame.candidates as i64);
        stats.gpu_particle_cull_dispatch_workgroups = particle_frame
            .as_ref()
            .map_or(0, |frame| frame.draws.len() as i64);
        stats.gpu_particle_indirect_draw_count = particle_frame
            .as_ref()
            .map_or(0, |frame| frame.draws.len() as i64);
        stats.gpu_particle_simulation_batch_count = simulation_report.batch_count;
        stats.gpu_particle_simulation_particle_count = simulation_report.particle_count;
        stats.gpu_particle_simulation_dispatch_workgroups = simulation_report.dispatch_workgroups;
        stats.gpu_particle_simulation_event_capacity = simulation_report.event_capacity;
        stats.gpu_particle_simulation_event_buffer_bytes = simulation_report.event_buffer_bytes;
        stats.gpu_particle_simulation_encode_ns = simulation_time.as_nanos() as u64;
        stats.gpu_particle_render_instance_count = simulation_report.render_instance_count;
        stats.gpu_particle_instance_dispatch_workgroups =
            simulation_report.instance_dispatch_workgroups;
        stats.gpu_particle_sort_pass_count = simulation_report.sort_pass_count;
        stats.gpu_particle_sort_item_count = simulation_report.sort_item_count;
        stats.gpu_particle_sort_padded_item_count = simulation_report.sort_padded_item_count;
        stats.gpu_particle_sort_dispatch_workgroups = simulation_report.sort_dispatch_workgroups;
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.last_frame_stats = stats;
            state.last_error = None;
        }
        Ok(())
    }

    fn encode_in_game_ui(
        &self,
        packet: &RenderPacket,
        ui_provider: Option<&dyn InGameUIProviding>,
        color: Texture,
        commands: &mut CommandBuffer,
    ) -> RhiResult<Option<crate::surface::in_game_ui_providing::InGameUIRecording>> {
        let Some(provider) = ui_provider else {
            return Ok(None);
        };
        // Swift passes the borrowed command buffer; the RHI records into an
        // owned buffer, so the frame's buffer is handed to the provider and
        // the recorded buffer comes back through the outcome.
        let hud_commands = std::mem::replace(commands, CommandBuffer::new());
        let outcome = provider.record_in_game_ui(
            packet,
            &packet.scene_snapshot,
            NativeInGameUITarget::new(
                self.device.clone(),
                hud_commands,
                RenderColorTarget {
                    texture: color,
                    load_action: ColorLoadAction::Load,
                    store: true,
                    resolve_texture: None,
                },
                cove_graphics::rhi::TextureFormat::Bgra8Unorm,
            ),
        );
        let outcome = match outcome {
            Ok(outcome) => outcome,
            Err(error) => {
                // Keep the partially recorded buffer so the caller can still
                // finish the frame cleanly before surfacing the error.
                *commands = error.commands;
                return Err(error.error);
            }
        };
        *commands = outcome.commands;
        Ok(outcome.recording)
    }

    fn ensure_targets(&self, size: RenderDrawableSize, hdr: bool) -> RhiResult<()> {
        if let Some(window_target) = &self.window_target {
            window_target.configure(size)?;
        }
        // Direct swapchain rendering needs matching depth dimensions. HDR and
        // offscreen targets share the production grow-only viewport policy.
        let mut guard = self
            .targets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let previous = guard
            .as_ref()
            .map(|targets| targets.size)
            .unwrap_or(RenderDrawableSize::new(0, 0));
        let post_size = if hdr {
            self.post.targets().map(|targets| targets.size)
        } else {
            None
        };
        let current = RenderDrawableSize::new(
            previous.width.max(post_size.map_or(0, |size| size.width)),
            previous.height.max(post_size.map_or(0, |size| size.height)),
        );
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs_f64())
            .unwrap_or_default();
        let mut sizing = ViewportTargetSizing::new();
        let capacity = if self.window_target.is_some() && !hdr {
            size
        } else {
            sizing.capacity(current, size, now)
        };
        if guard
            .as_ref()
            .is_some_and(|targets| targets.size == capacity && targets.hdr.is_some() == hdr)
        {
            return Ok(());
        }
        let replacement =
            NativeRenderTargets::make(&self.device, capacity, self.window_target.is_none(), hdr)?;
        *guard = Some(replacement);
        Ok(())
    }
}

impl RenderPacketConsumer for NativeRenderer {
    fn initialize(&mut self) {
        NativeRenderer::initialize(self);
    }

    fn render(&mut self, packet: &RenderPacket) {
        NativeRenderer::render(self, packet);
    }

    fn current_frame_stats(&self) -> RenderFrameStats {
        NativeRenderer::current_frame_stats(self)
    }

    fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        NativeRenderer::current_viewport_surface_state(self)
    }

    fn drain_gpu_particle_simulation_event_snapshots(
        &mut self,
        max_snapshots: usize,
    ) -> Result<Vec<GPUParticleSimulationEventSnapshot>, RhiError> {
        NativeRenderer::drain_gpu_particle_simulation_event_snapshots(self, max_snapshots)
    }
}

// Swift's rendererPreparationStep preserves cancellation and per-stage progress.
fn renderer_preparation_step<T>(
    context: Option<&ResourcePreparationContext>,
    label: &str,
    operation: impl FnOnce() -> RhiResult<T>,
) -> RhiResult<T> {
    if let Some(context) = context {
        context.step(label, operation)
    } else {
        operation()
    }
}
