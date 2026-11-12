//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Shaders/ShaderCatalogTests.swift`.

use cove_graphics::rhi::{GraphicsApi, ShaderStage};
use diffuse_math::simd::simd_compat::Float4;
use diffuse_render::native::targets::native_shader_library::NativeShaderLibrary;
use diffuse_render::{
    RenderFramePlanner, RenderPassKind, RenderSettings, RenderShadowSettings,
    StylizedCharacterStyle,
};

/// The resource bundle ships offline shader artifacts; without a deployed
/// `DiffuseRuntime_RenderBackend` bundle the lookup cannot be exercised.
fn resource_bundle_available() -> bool {
    std::env::var_os("COVE_RESOURCE_PATH").is_some()
}

/// Editor grid follows screen-space lighting and precedes particles.
#[test]
fn editor_grid_pass_ordering() {
    assert!(!RenderSettings::new().viewport.grid_enabled);

    let mut settings = RenderSettings::new();
    settings.post_processing.ssao = true;
    settings.post_processing.ssr = true;
    settings.post_processing.taa = true;
    settings.viewport.offscreen = true;
    assert!(
        !RenderFramePlanner::make_plan(&settings)
            .passes
            .contains(&RenderPassKind::EditorGrid)
    );

    settings.viewport.grid_enabled = true;
    let passes = RenderFramePlanner::make_plan(&settings).passes;
    let grid_index = passes
        .iter()
        .position(|kind| *kind == RenderPassKind::EditorGrid)
        .expect("editor grid pass");
    let particle_index = passes
        .iter()
        .position(|kind| *kind == RenderPassKind::Particles)
        .expect("particles pass");
    assert!(grid_index < particle_index);
    assert!(RenderPassKind::OPAQUE_PASSES.contains(&RenderPassKind::EditorGrid));

    for pass in [
        RenderPassKind::BasePass,
        RenderPassKind::Ssao,
        RenderPassKind::Ssr,
    ] {
        if let Some(index) = passes.iter().position(|kind| *kind == pass) {
            assert!(index < grid_index, "{pass:?} must precede the editor grid");
        }
    }
    if let Some(taa) = passes.iter().position(|kind| *kind == RenderPassKind::Taa) {
        assert!(grid_index < taa, "editor grid must precede TAA");
    }
}

/// Bundled native shader inventory has code and reflected entry points.
#[test]
fn catalog_resolves_programs() {
    if !resource_bundle_available() {
        return;
    }

    let render = [
        "editor_grid",
        "editor_geometry",
        "opaque_mesh",
        "shadow_mesh",
        "skybox",
        "tonemap",
        "stylized_character",
        "outline",
        "particles",
        "ssao",
        "ssr",
        "taa",
        "bloom",
        "fxaa",
        "ink_paper_post",
    ];
    let compute = [
        "particle_cull_compact",
        "particle_simulate",
        "particle_spawn_append",
        "particle_state_clear",
        "particle_state_compact",
        "particle_metadata_reset",
        "particle_state_finalize",
        "particle_sort_prepare",
        "particle_sort_bitonic",
        "particle_sim_to_instance",
    ];

    for api in [GraphicsApi::Metal, GraphicsApi::Vulkan, GraphicsApi::Dx12] {
        for name in render {
            for stage in [ShaderStage::Vertex, ShaderStage::Fragment] {
                let shader = NativeShaderLibrary::artifact(name, api, stage)
                    .unwrap_or_else(|error| panic!("{api:?} {name} {stage:?}: {error}"));
                assert!(!shader.code.is_empty());
                assert!(!shader.entry_point.is_empty());
                assert_eq!(shader.stage, stage);
            }
        }
        for name in compute {
            let shader = NativeShaderLibrary::artifact(name, api, ShaderStage::Compute)
                .unwrap_or_else(|error| panic!("{api:?} {name} compute: {error}"));
            assert!(!shader.code.is_empty());
            assert!(shader.interface.threadgroup_size.x > 0);
        }
    }
}

/// Capability switches assemble the HDR frame graph in the correct order.
#[test]
fn planner_orders_hdr_passes() {
    let mut shadow_settings = RenderSettings::new();
    shadow_settings.shadows.enabled = true;
    shadow_settings.viewport.offscreen = true;
    let shadowed = RenderFramePlanner::make_plan(&shadow_settings);

    let mut post_settings = RenderSettings::new();
    post_settings.post_processing.fxaa = true;
    post_settings.post_processing.ssao = true;
    post_settings.post_processing.ssr = true;
    post_settings.post_processing.taa = true;
    post_settings.post_processing.bloom = true;
    post_settings.viewport.offscreen = true;
    let with_post = RenderFramePlanner::make_plan(&post_settings);

    let expected_shadowed = [
        RenderPassKind::DepthPrepass,
        RenderPassKind::ShadowPass,
        RenderPassKind::Skybox,
        RenderPassKind::BasePass,
        RenderPassKind::TransparentMeshes,
        RenderPassKind::Particles,
        RenderPassKind::Tonemap,
        RenderPassKind::ViewportResolve,
    ];
    let expected_with_post = [
        RenderPassKind::DepthPrepass,
        RenderPassKind::Skybox,
        RenderPassKind::BasePass,
        RenderPassKind::Ssao,
        RenderPassKind::Ssr,
        RenderPassKind::Taa,
        RenderPassKind::TransparentMeshes,
        RenderPassKind::Particles,
        RenderPassKind::Bloom,
        RenderPassKind::Tonemap,
        RenderPassKind::Fxaa,
        RenderPassKind::ViewportResolve,
    ];

    assert_eq!(shadowed.passes, expected_shadowed);
    assert_eq!(with_post.passes, expected_with_post);
}

/// Progressive refinement drops SSR only while the opaque scene is moving.
#[test]
fn motion_refinement_drops_ssr() {
    let full = [
        RenderPassKind::DepthPrepass,
        RenderPassKind::Skybox,
        RenderPassKind::BasePass,
        RenderPassKind::Ssao,
        RenderPassKind::Ssr,
        RenderPassKind::Taa,
        RenderPassKind::TransparentMeshes,
        RenderPassKind::Particles,
        RenderPassKind::Bloom,
        RenderPassKind::Tonemap,
        RenderPassKind::ViewportResolve,
    ];

    assert_eq!(
        RenderFramePlanner::motion_refined_passes(&full, false),
        full
    );

    let moving = RenderFramePlanner::motion_refined_passes(&full, true);
    assert!(!moving.contains(&RenderPassKind::Ssr));
    assert_eq!(
        moving,
        full.iter()
            .copied()
            .filter(|kind| *kind != RenderPassKind::Ssr)
            .collect::<Vec<_>>()
    );
    assert!(moving.contains(&RenderPassKind::Ssao));
    assert!(moving.contains(&RenderPassKind::Taa));
}

/// Shadow settings define the renderer shadow contract.
///
/// The Rust port keeps raw values in the settings and sanitises them where the
/// shadow atlas consumes them, so the test pins the defaults and the sanitising
/// helpers instead of an initializer that clamps every field.
#[test]
fn shadow_settings_define_contract() {
    let settings = RenderShadowSettings::new_disabled();

    assert!(!settings.enabled);
    assert_eq!(settings.map_resolution, 1024);
    assert_eq!(settings.depth_bias, 0.006);
    assert_eq!(settings.strength, 0.62);
    assert_eq!(settings.max_shadowed_directional_lights, 1);
    assert_eq!(settings.directional_cascade_count, 1);
    assert_eq!(settings.directional_cascade_split_lambda, 0.55);

    assert_eq!(RenderShadowSettings::sanitized_map_resolution(99), 128);
    assert_eq!(RenderShadowSettings::sanitized_map_resolution(99_999), 4096);
    assert_eq!(
        RenderShadowSettings::sanitized_directional_cascade_count(99),
        4
    );
    assert_eq!(
        RenderShadowSettings::sanitized_directional_cascade_count(0),
        1
    );

    let preview = RenderShadowSettings::directional_preview();
    assert!(preview.enabled);

    let mut render_settings = RenderSettings::new();
    render_settings.shadows = preview;
    assert!(render_settings.shadows.enabled);
    render_settings.shadows.enabled = false;
    assert!(!render_settings.shadows.enabled);
    assert_eq!(
        RenderFramePlanner::make_plan(&render_settings).passes,
        [
            RenderPassKind::DepthPrepass,
            RenderPassKind::Skybox,
            RenderPassKind::BasePass,
            RenderPassKind::TransparentMeshes,
            RenderPassKind::Particles,
            RenderPassKind::Tonemap,
        ]
    );
}

/// Stylized character shading schedules outline after base pass.
#[test]
fn planner_schedules_stylized_outline() {
    let mut settings = RenderSettings::new();
    settings.post_processing.bloom = true;
    settings.stylization.enabled = true;

    let plan = RenderFramePlanner::make_plan(&settings);

    assert_eq!(
        plan.passes,
        [
            RenderPassKind::DepthPrepass,
            RenderPassKind::Skybox,
            RenderPassKind::BasePass,
            RenderPassKind::Outline,
            RenderPassKind::InkPaperPost,
            RenderPassKind::TransparentMeshes,
            RenderPassKind::Particles,
            RenderPassKind::Bloom,
            RenderPassKind::Tonemap,
        ]
    );
}

/// Stylized character settings carry card ink style parameters.
#[test]
fn stylized_character_settings_carry_style_parameters() {
    let style = StylizedCharacterStyle::new(
        Float4::new(0.2, 0.6, 0.0, 0.0),
        Float4::new(0.25, 0.55, 1.0, 0.0),
        Float4::new(0.8, 0.75, 0.65, 1.0),
        0.04,
        0.22,
        0.09,
        0.02,
    );
    let mut settings = RenderSettings::new();
    settings.stylization.enabled = true;
    settings.stylization.style = style;

    assert!(settings.stylization.enabled);
    assert_eq!(settings.stylization.style, style);
    assert_eq!(
        RenderSettings::new().stylization.style,
        StylizedCharacterStyle::colorful_ink_card()
    );
}
