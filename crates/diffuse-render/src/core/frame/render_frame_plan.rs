//! The ordered pass list for one frame and its planner.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Frame/RenderFramePlan.swift`.

use crate::core::render_settings::RenderSettings;

/// `RenderPassKind` — a `String`-backed enum; the raw values are the case names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RenderPassKind {
    DepthPrepass,
    ShadowPass,
    Skybox,
    BasePass,
    EditorGrid,
    TransparentMeshes,
    Particles,
    Outline,
    InkPaperPost,
    Ssao,
    Ssr,
    Taa,
    Bloom,
    Fxaa,
    Tonemap,
    ViewportResolve,
    /// Dynamic HUD overlay, recorded after scene post-processing.
    InGameUI,
    /// Editor geometry composites after post-processing, outside opaque history.
    EditorGeometry,
}

impl RenderPassKind {
    pub const fn raw_value(self) -> &'static str {
        match self {
            RenderPassKind::DepthPrepass => "depthPrepass",
            RenderPassKind::ShadowPass => "shadowPass",
            RenderPassKind::Skybox => "skybox",
            RenderPassKind::BasePass => "basePass",
            RenderPassKind::EditorGrid => "editorGrid",
            RenderPassKind::TransparentMeshes => "transparentMeshes",
            RenderPassKind::Particles => "particles",
            RenderPassKind::Outline => "outline",
            RenderPassKind::InkPaperPost => "inkPaperPost",
            RenderPassKind::Ssao => "ssao",
            RenderPassKind::Ssr => "ssr",
            RenderPassKind::Taa => "taa",
            RenderPassKind::Bloom => "bloom",
            RenderPassKind::Fxaa => "fxaa",
            RenderPassKind::Tonemap => "tonemap",
            RenderPassKind::ViewportResolve => "viewportResolve",
            RenderPassKind::InGameUI => "inGameUI",
            RenderPassKind::EditorGeometry => "editorGeometry",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "depthPrepass" => Some(RenderPassKind::DepthPrepass),
            "shadowPass" => Some(RenderPassKind::ShadowPass),
            "skybox" => Some(RenderPassKind::Skybox),
            "basePass" => Some(RenderPassKind::BasePass),
            "editorGrid" => Some(RenderPassKind::EditorGrid),
            "transparentMeshes" => Some(RenderPassKind::TransparentMeshes),
            "particles" => Some(RenderPassKind::Particles),
            "outline" => Some(RenderPassKind::Outline),
            "inkPaperPost" => Some(RenderPassKind::InkPaperPost),
            "ssao" => Some(RenderPassKind::Ssao),
            "ssr" => Some(RenderPassKind::Ssr),
            "taa" => Some(RenderPassKind::Taa),
            "bloom" => Some(RenderPassKind::Bloom),
            "fxaa" => Some(RenderPassKind::Fxaa),
            "tonemap" => Some(RenderPassKind::Tonemap),
            "viewportResolve" => Some(RenderPassKind::ViewportResolve),
            "inGameUI" => Some(RenderPassKind::InGameUI),
            "editorGeometry" => Some(RenderPassKind::EditorGeometry),
            _ => None,
        }
    }

    /// `CaseIterable` order.
    pub const ALL: [RenderPassKind; 18] = [
        RenderPassKind::DepthPrepass,
        RenderPassKind::ShadowPass,
        RenderPassKind::Skybox,
        RenderPassKind::BasePass,
        RenderPassKind::EditorGrid,
        RenderPassKind::TransparentMeshes,
        RenderPassKind::Particles,
        RenderPassKind::Outline,
        RenderPassKind::InkPaperPost,
        RenderPassKind::Ssao,
        RenderPassKind::Ssr,
        RenderPassKind::Taa,
        RenderPassKind::Bloom,
        RenderPassKind::Fxaa,
        RenderPassKind::Tonemap,
        RenderPassKind::ViewportResolve,
        RenderPassKind::InGameUI,
        RenderPassKind::EditorGeometry,
    ];

    /// Passes whose output is a pure function of the opaque scene inputs
    /// (geometry, lights, camera, settings) — i.e. everything before the
    /// transparent `particles` overlay. The opaque-render cache may skip these
    /// and reuse a snapshot when those inputs are unchanged.
    pub fn is_opaque_pass(self) -> bool {
        matches!(
            self,
            RenderPassKind::DepthPrepass
                | RenderPassKind::ShadowPass
                | RenderPassKind::Skybox
                | RenderPassKind::BasePass
                | RenderPassKind::Outline
                | RenderPassKind::InkPaperPost
                | RenderPassKind::Ssao
                | RenderPassKind::Ssr
                | RenderPassKind::Taa
                | RenderPassKind::EditorGrid
        )
    }

    /// `opaquePasses` as an ordered array; membership is `is_opaque_pass`.
    pub const OPAQUE_PASSES: [RenderPassKind; 10] = [
        RenderPassKind::DepthPrepass,
        RenderPassKind::ShadowPass,
        RenderPassKind::Skybox,
        RenderPassKind::BasePass,
        RenderPassKind::Outline,
        RenderPassKind::InkPaperPost,
        RenderPassKind::Ssao,
        RenderPassKind::Ssr,
        RenderPassKind::Taa,
        RenderPassKind::EditorGrid,
    ];
}

/// The ordered pass list for one frame.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderFramePlan {
    pub passes: Vec<RenderPassKind>,
}

impl RenderFramePlan {
    pub fn new(passes: Vec<RenderPassKind>) -> Self {
        RenderFramePlan { passes }
    }
}

/// `RenderFramePlanner` — builds the pass list from the active settings.
pub enum RenderFramePlanner {}

impl RenderFramePlanner {
    pub fn make_plan(settings: &RenderSettings) -> RenderFramePlan {
        let mut passes: Vec<RenderPassKind> = Vec::new();

        if settings.shading.depth_prepass {
            passes.push(RenderPassKind::DepthPrepass);
        }
        if settings.shadows.enabled && settings.shadows.max_shadowed_directional_lights > 0 {
            passes.push(RenderPassKind::ShadowPass);
        }
        if settings.shading.pbr {
            passes.push(RenderPassKind::Skybox);
        }
        passes.push(RenderPassKind::BasePass);
        Self::append_stylized_passes_if_needed(settings, &mut passes);
        if settings.post_processing.ssao {
            passes.push(RenderPassKind::Ssao);
        }
        if settings.post_processing.ssr {
            passes.push(RenderPassKind::Ssr);
        }
        if settings.post_processing.taa {
            passes.push(RenderPassKind::Taa);
        }
        if settings.post_processing.bloom {
            passes.push(RenderPassKind::Bloom);
        }
        if settings.shading.pbr {
            passes.push(RenderPassKind::Tonemap);
        }
        if settings.post_processing.fxaa {
            passes.push(RenderPassKind::Fxaa);
        }
        if settings.viewport.offscreen {
            passes.push(RenderPassKind::ViewportResolve);
        }

        // Reference lines use scene depth, without contributing to depth or
        // screen-space lighting. Draw before TAA so its history and current
        // image both contain the grid, then include it in the opaque snapshot.
        if settings.viewport.grid_enabled
            && let Some(last_opaque) = passes.iter().rposition(|kind| kind.is_opaque_pass())
        {
            let insert_at = match passes.iter().position(|kind| *kind == RenderPassKind::Taa) {
                Some(index) => index,
                // `passes.index(after: lastOpaque)`.
                None => last_opaque + 1,
            };
            passes.insert(insert_at, RenderPassKind::EditorGrid);
        }

        // Transparent billboard particles composite after every opaque and
        // opaque-screen-space pass (so they sit on the lit, AO'd, reflected
        // image) but before bloom/tonemap. This also marks the "lit opaque"
        // boundary that the opaque-render cache snapshots: everything up to
        // (and excluding) particles is a pure function of the opaque inputs.
        if let Some(last_opaque) = passes.iter().rposition(|kind| kind.is_opaque_pass()) {
            let insert_at = last_opaque + 1;
            passes.insert(insert_at, RenderPassKind::TransparentMeshes);
            passes.insert(insert_at + 1, RenderPassKind::Particles);
        }

        RenderFramePlan::new(passes)
    }

    /// Progressive refinement: while the opaque scene is moving (camera or
    /// geometry changing frame-to-frame), drop the most expensive screen-space
    /// pass (SSR) so interaction stays responsive. Full quality returns the
    /// moment the scene settles. Stacks with the editor's interaction
    /// render-scale downscale.
    pub fn motion_refined_passes(
        passes: &[RenderPassKind],
        opaque_moving: bool,
    ) -> Vec<RenderPassKind> {
        if !opaque_moving {
            return passes.to_vec();
        }
        passes
            .iter()
            .copied()
            .filter(|kind| *kind != RenderPassKind::Ssr)
            .collect()
    }

    fn append_stylized_passes_if_needed(
        settings: &RenderSettings,
        passes: &mut Vec<RenderPassKind>,
    ) {
        if settings.stylization.enabled {
            passes.push(RenderPassKind::Outline);
            passes.push(RenderPassKind::InkPaperPost);
        }
    }
}
