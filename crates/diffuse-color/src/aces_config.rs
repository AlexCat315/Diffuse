//! `ACESConfig` — the ACES configuration preset and colour-space vocabulary.

/// `ACESConfigPreset`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ACESConfigPreset {
    /// ACES studio config subset.
    Studio,
    /// Full ACES reference config.
    Reference,
    Custom,
}

impl ACESConfigPreset {
    pub const ALL: [ACESConfigPreset; 3] = [
        ACESConfigPreset::Studio,
        ACESConfigPreset::Reference,
        ACESConfigPreset::Custom,
    ];

    /// `CaseIterable.allCases`.
    pub fn all_cases() -> &'static [ACESConfigPreset] {
        &Self::ALL
    }

    /// `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            ACESConfigPreset::Studio => "studio",
            ACESConfigPreset::Reference => "reference",
            ACESConfigPreset::Custom => "custom",
        }
    }
}

/// `ACESColorSpace`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ACESColorSpace {
    AcesCg,
    Aces2065,
    Acescct,
    SceneLinear,
}

impl ACESColorSpace {
    pub const ALL: [ACESColorSpace; 4] = [
        ACESColorSpace::AcesCg,
        ACESColorSpace::Aces2065,
        ACESColorSpace::Acescct,
        ACESColorSpace::SceneLinear,
    ];

    /// `CaseIterable.allCases`.
    pub fn all_cases() -> &'static [ACESColorSpace] {
        &Self::ALL
    }

    /// `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            ACESColorSpace::AcesCg => "ACES - ACEScg",
            ACESColorSpace::Aces2065 => "ACES - ACES2065-1",
            ACESColorSpace::Acescct => "ACEScct",
            ACESColorSpace::SceneLinear => "scene_linear",
        }
    }
}

/// `ACESDisplayTransform`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ACESDisplayTransform {
    SRgb,
    Rec709,
    Rec2020,
    P3Dci,
    P3D65,
}

impl ACESDisplayTransform {
    pub const ALL: [ACESDisplayTransform; 5] = [
        ACESDisplayTransform::SRgb,
        ACESDisplayTransform::Rec709,
        ACESDisplayTransform::Rec2020,
        ACESDisplayTransform::P3Dci,
        ACESDisplayTransform::P3D65,
    ];

    /// `CaseIterable.allCases`.
    pub fn all_cases() -> &'static [ACESDisplayTransform] {
        &Self::ALL
    }

    /// `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            ACESDisplayTransform::SRgb => "sRGB",
            ACESDisplayTransform::Rec709 => "Rec.709",
            ACESDisplayTransform::Rec2020 => "Rec.2020",
            ACESDisplayTransform::P3Dci => "P3-DCI",
            ACESDisplayTransform::P3D65 => "P3-D65",
        }
    }
}

/// `ACESViewTransform`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ACESViewTransform {
    UnToneMapped,
    SdrVideo,
    HdrVideo1000,
    HdrVideo4000,
}

impl ACESViewTransform {
    pub const ALL: [ACESViewTransform; 4] = [
        ACESViewTransform::UnToneMapped,
        ACESViewTransform::SdrVideo,
        ACESViewTransform::HdrVideo1000,
        ACESViewTransform::HdrVideo4000,
    ];

    /// `CaseIterable.allCases`.
    pub fn all_cases() -> &'static [ACESViewTransform] {
        &Self::ALL
    }

    /// `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            ACESViewTransform::UnToneMapped => "Un-tone-mapped",
            ACESViewTransform::SdrVideo => "SDR Video",
            ACESViewTransform::HdrVideo1000 => "HDR Video (1000 nits)",
            ACESViewTransform::HdrVideo4000 => "HDR Video (4000 nits)",
        }
    }
}

/// `ACESConfig`: the preset plus the working space, display and view transforms.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ACESConfig {
    pub config_preset: ACESConfigPreset,
    pub working_space: ACESColorSpace,
    pub display_transform: ACESDisplayTransform,
    pub view_transform: ACESViewTransform,
}

impl Default for ACESConfig {
    /// Swift's defaulted initializer: `.studio`, `.acesCG`, `.sRGB`, `.unToneMapped`.
    fn default() -> Self {
        Self::new(
            ACESConfigPreset::Studio,
            ACESColorSpace::AcesCg,
            ACESDisplayTransform::SRgb,
            ACESViewTransform::UnToneMapped,
        )
    }
}

impl ACESConfig {
    pub fn new(
        preset: ACESConfigPreset,
        working_space: ACESColorSpace,
        display: ACESDisplayTransform,
        view: ACESViewTransform,
    ) -> Self {
        ACESConfig {
            config_preset: preset,
            working_space,
            display_transform: display,
            view_transform: view,
        }
    }

    /// `colorPipelineDescription`.
    pub fn color_pipeline_description(&self) -> String {
        format!(
            "{} / {} → {} ({})",
            self.config_preset.raw_value(),
            self.working_space.raw_value(),
            self.display_transform.raw_value(),
            self.view_transform.raw_value()
        )
    }
}
