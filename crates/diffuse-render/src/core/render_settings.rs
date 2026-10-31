//! Render settings: shading, post-processing, visibility, viewport, shadows and
//! stylization.

use diffuse_math::simd::simd_compat::{Float4, simd_clamp_scalar};

/// The stylized-character look. Defaults are Swift's `colorfulInkCard`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StylizedCharacterStyle {
    pub toon_thresholds: Float4,
    pub toon_levels: Float4,
    pub ink_wash_color: Float4,
    pub paper_grain_strength: f32,
    pub rim_strength: f32,
    pub material_bias_strength: f32,
    pub outline_width: f32,
}

impl StylizedCharacterStyle {
    #[allow(clippy::too_many_arguments)]
    #[inline]
    pub fn new(
        toon_thresholds: Float4,
        toon_levels: Float4,
        ink_wash_color: Float4,
        paper_grain_strength: f32,
        rim_strength: f32,
        material_bias_strength: f32,
        outline_width: f32,
    ) -> Self {
        StylizedCharacterStyle {
            toon_thresholds,
            toon_levels,
            ink_wash_color,
            paper_grain_strength,
            rim_strength,
            material_bias_strength,
            outline_width,
        }
    }

    /// `StylizedCharacterStyle.colorfulInkCard`, i.e. the Swift default values.
    pub fn colorful_ink_card() -> Self {
        StylizedCharacterStyle {
            toon_thresholds: Float4::new(0.24, 0.58, 0.0, 0.0),
            toon_levels: Float4::new(0.30, 0.58, 1.0, 0.0),
            ink_wash_color: Float4::new(0.92, 0.88, 0.78, 1.0),
            paper_grain_strength: 0.035,
            rim_strength: 0.18,
            material_bias_strength: 0.08,
            outline_width: 0.015,
        }
    }
}

impl Default for StylizedCharacterStyle {
    fn default() -> Self {
        Self::colorful_ink_card()
    }
}

/// Which directional light casts shadows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DirectionalLightSelection {
    #[default]
    Brightest,
}

impl DirectionalLightSelection {
    pub const fn raw_value(self) -> &'static str {
        match self {
            DirectionalLightSelection::Brightest => "brightest",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "brightest" => Some(DirectionalLightSelection::Brightest),
            _ => None,
        }
    }

    /// `CaseIterable` order.
    pub const ALL: [DirectionalLightSelection; 1] = [DirectionalLightSelection::Brightest];
}

/// Shadow-map configuration. Every field is sanitised in the initializer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderShadowSettings {
    pub enabled: bool,
    pub map_resolution: u32,
    pub depth_bias: f32,
    pub strength: f32,
    pub max_shadowed_directional_lights: usize,
    pub directional_cascade_count: usize,
    pub directional_cascade_split_lambda: f32,
    pub directional_light_selection: DirectionalLightSelection,
}

impl RenderShadowSettings {
    /// Swift's default-argument initializer, including every clamp.
    pub fn new_disabled() -> Self {
        RenderShadowSettings {
            enabled: false,
            map_resolution: Self::sanitized_map_resolution(1024),
            depth_bias: 0.006f32.max(0.0),
            strength: simd_clamp_scalar(0.62, 0.0, 1.0),
            max_shadowed_directional_lights: 1usize,
            directional_cascade_count: Self::sanitized_directional_cascade_count(1),
            directional_cascade_split_lambda: simd_clamp_scalar(0.55, 0.0, 1.0),
            directional_light_selection: DirectionalLightSelection::Brightest,
        }
    }

    /// `RenderShadowSettings.directionalPreview` — enabled with default values.
    pub fn directional_preview() -> Self {
        let mut settings = Self::new_disabled();
        settings.enabled = true;
        settings
    }

    /// `min(max(value, 128), 4096)`.
    pub fn sanitized_map_resolution(value: u32) -> u32 {
        value.clamp(128, 4096)
    }

    /// `min(max(value, 1), 4)`.
    pub fn sanitized_directional_cascade_count(value: usize) -> usize {
        value.clamp(1, 4)
    }
}

impl Default for RenderShadowSettings {
    fn default() -> Self {
        Self::new_disabled()
    }
}

/// Viewport debug visualisation (the editor's "view mode").
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DebugViewMode {
    #[default]
    Shaded,
    Unlit,
    BaseColor,
    WorldNormal,
    Roughness,
    Metallic,
}

impl DebugViewMode {
    /// The raw value is forwarded to the mesh shader via
    /// `exposure_light_count.z`.
    pub const fn raw_value(self) -> i64 {
        match self {
            DebugViewMode::Shaded => 0,
            DebugViewMode::Unlit => 1,
            DebugViewMode::BaseColor => 2,
            DebugViewMode::WorldNormal => 3,
            DebugViewMode::Roughness => 4,
            DebugViewMode::Metallic => 5,
        }
    }

    pub fn from_raw_value(value: i64) -> Option<Self> {
        match value {
            0 => Some(DebugViewMode::Shaded),
            1 => Some(DebugViewMode::Unlit),
            2 => Some(DebugViewMode::BaseColor),
            3 => Some(DebugViewMode::WorldNormal),
            4 => Some(DebugViewMode::Roughness),
            5 => Some(DebugViewMode::Metallic),
            _ => None,
        }
    }

    pub const ALL: [DebugViewMode; 6] = [
        DebugViewMode::Shaded,
        DebugViewMode::Unlit,
        DebugViewMode::BaseColor,
        DebugViewMode::WorldNormal,
        DebugViewMode::Roughness,
        DebugViewMode::Metallic,
    ];
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Shading {
    pub pbr: bool,
    pub depth_prepass: bool,
    pub debug_view_mode: DebugViewMode,
}

impl Shading {
    pub fn new() -> Self {
        Shading {
            pbr: true,
            depth_prepass: true,
            debug_view_mode: DebugViewMode::Shaded,
        }
    }
}

impl Default for Shading {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PostProcessing {
    pub fxaa: bool,
    pub ssao: bool,
    pub ssr: bool,
    pub taa: bool,
    pub bloom: bool,
}

impl PostProcessing {
    pub fn new() -> Self {
        PostProcessing {
            fxaa: false,
            ssao: false,
            ssr: false,
            taa: false,
            bloom: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Visibility {
    pub frustum_culling: bool,
    pub mesh_instancing: bool,
    pub distance_lod: bool,
    pub grouped_draw_by_mesh: bool,
}

impl Visibility {
    pub fn new() -> Self {
        Visibility {
            frustum_culling: true,
            mesh_instancing: true,
            distance_lod: true,
            grouped_draw_by_mesh: false,
        }
    }
}

impl Default for Visibility {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Backdrop {
    #[default]
    Sky,
    Studio,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ViewportSettings {
    pub offscreen: bool,
    pub backdrop: Backdrop,
    pub grid_enabled: bool,
    pub grid_spacing: f32,
}

impl ViewportSettings {
    pub fn new() -> Self {
        ViewportSettings {
            offscreen: false,
            backdrop: Backdrop::Sky,
            grid_enabled: false,
            grid_spacing: 1.0,
        }
    }

    /// Swift's `normalize()`: a non-finite or non-positive spacing becomes 1.
    pub fn normalize(&mut self) {
        if !self.grid_spacing.is_finite() || self.grid_spacing <= 0.0 {
            self.grid_spacing = 1.0;
        }
    }
}

impl Default for ViewportSettings {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stylization {
    pub enabled: bool,
    pub style: StylizedCharacterStyle,
}

impl Stylization {
    pub fn new() -> Self {
        Stylization {
            enabled: false,
            style: StylizedCharacterStyle::colorful_ink_card(),
        }
    }
}

impl Default for Stylization {
    fn default() -> Self {
        Self::new()
    }
}

/// The full render settings tree.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderSettings {
    pub shading: Shading,
    pub post_processing: PostProcessing,
    pub visibility: Visibility,
    pub viewport: ViewportSettings,
    pub shadows: RenderShadowSettings,
    pub stylization: Stylization,
}

impl RenderSettings {
    pub fn new() -> Self {
        RenderSettings {
            shading: Shading::new(),
            post_processing: PostProcessing::new(),
            visibility: Visibility::new(),
            viewport: ViewportSettings::new(),
            shadows: RenderShadowSettings::new_disabled(),
            stylization: Stylization::new(),
        }
    }

    /// `init(configure:)` — runs the closure, then normalizes the viewport.
    pub fn configured(configure: impl FnOnce(&mut RenderSettings)) -> Self {
        let mut settings = RenderSettings::new();
        configure(&mut settings);
        settings.viewport.normalize();
        settings
    }
}

impl Default for RenderSettings {
    fn default() -> Self {
        Self::new()
    }
}
