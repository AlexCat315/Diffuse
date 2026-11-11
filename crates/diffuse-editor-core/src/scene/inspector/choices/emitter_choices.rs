//! `Editor/Sources/EditorCore/Scene/Inspector/Choices/EmitterChoices.swift`.

use diffuse_scene::particles::particle_types::{
    ParticleBlendMode, ParticleCollisionMode, ParticleEmissionShape, ParticleForceMode,
    ParticleRenderAlignment, ParticleRenderBoundsMode, ParticleRenderMode,
    ParticleSimulationBackend, ParticleSimulationSpace, ParticleSortMode,
    ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
};

use crate::localization::localized;
use crate::scene::inspector::enum_options::EditorInspectorEnumOption;

impl EditorInspectorEnumOption for ParticleEmissionShape {
    const ALL: &'static [Self] = &ParticleEmissionShape::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleEmissionShape::Sphere => localized("Sphere"),
            ParticleEmissionShape::Box => localized("Box"),
            ParticleEmissionShape::Cone => localized("Cone"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleCollisionMode {
    const ALL: &'static [Self] = &ParticleCollisionMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleCollisionMode::None => localized("None"),
            ParticleCollisionMode::LocalPlane => localized("Local Plane"),
            ParticleCollisionMode::WorldPlane => localized("World Plane"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleSimulationSpace {
    const ALL: &'static [Self] = &ParticleSimulationSpace::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleSimulationSpace::Local => localized("Local"),
            ParticleSimulationSpace::World => localized("World"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleSimulationBackend {
    const ALL: &'static [Self] = &ParticleSimulationBackend::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleSimulationBackend::Cpu => localized("CPU"),
            ParticleSimulationBackend::GpuIfSupported => localized("GPU Preferred"),
            ParticleSimulationBackend::GpuRequired => localized("GPU Required"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleBlendMode {
    const ALL: &'static [Self] = &ParticleBlendMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleBlendMode::Alpha => localized("Alpha"),
            ParticleBlendMode::Additive => localized("Additive"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleRenderMode {
    const ALL: &'static [Self] = &ParticleRenderMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleRenderMode::Billboard => localized("Billboard"),
            ParticleRenderMode::Ribbon => localized("Ribbon"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleSortMode {
    const ALL: &'static [Self] = &ParticleSortMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleSortMode::DistanceDescending => localized("Back to Front"),
            ParticleSortMode::DistanceAscending => localized("Front to Back"),
            ParticleSortMode::OldestFirst => localized("Oldest First"),
            ParticleSortMode::YoungestFirst => localized("Youngest First"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleTextureSheetPlaybackMode {
    const ALL: &'static [Self] = &ParticleTextureSheetPlaybackMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleTextureSheetPlaybackMode::Automatic => localized("Auto"),
            ParticleTextureSheetPlaybackMode::Lifetime => localized("Lifetime"),
            ParticleTextureSheetPlaybackMode::PlayOnce => localized("Play Once"),
            ParticleTextureSheetPlaybackMode::Loop => localized("Loop"),
            ParticleTextureSheetPlaybackMode::SingleFrame => localized("Single Frame"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleRenderAlignment {
    const ALL: &'static [Self] = &ParticleRenderAlignment::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleRenderAlignment::Billboard => localized("Billboard"),
            ParticleRenderAlignment::Velocity => localized("Velocity"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleRenderBoundsMode {
    const ALL: &'static [Self] = &ParticleRenderBoundsMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleRenderBoundsMode::Disabled => localized("Disabled"),
            ParticleRenderBoundsMode::Manual => localized("Manual"),
            ParticleRenderBoundsMode::Automatic => localized("Automatic"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleForceMode {
    const ALL: &'static [Self] = &ParticleForceMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleForceMode::None => localized("None"),
            ParticleForceMode::Radial => localized("Radial"),
            ParticleForceMode::Vortex => localized("Vortex"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleVectorFieldMode {
    const ALL: &'static [Self] = &ParticleVectorFieldMode::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleVectorFieldMode::None => localized("None"),
            ParticleVectorFieldMode::Uniform => localized("Uniform"),
            ParticleVectorFieldMode::Curl => localized("Curl"),
        }
    }
}

impl EditorInspectorEnumOption for ParticleSubEmitterTrigger {
    const ALL: &'static [Self] = &ParticleSubEmitterTrigger::ALL;

    fn inspector_option_id(&self) -> String {
        self.raw_value().to_string()
    }

    fn inspector_option_label(&self) -> String {
        match self {
            ParticleSubEmitterTrigger::None => localized("None"),
            ParticleSubEmitterTrigger::Death => localized("Death"),
            ParticleSubEmitterTrigger::Collision => localized("Collision"),
        }
    }
}
