//! The authored particle module stack: module payloads, validation and repair.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleModules.swift`.

use std::collections::{HashMap, HashSet};

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_clamp_scalar};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_curve::ParticleCurve;
use crate::particles::particle_events::ParticleSubEmitter;
use crate::particles::particle_gpu_simulation_plan::{
    ParticleGPUSimulationPlan, ParticleGPUSimulationPlanStatus,
    ParticleGPUSimulationUnsupportedReason,
};
use crate::particles::particle_types::{
    ParticleBlendMode, ParticleCollisionMode, ParticleEmissionShape, ParticleForceMode,
    ParticleRenderAlignment, ParticleRenderBoundsMode, ParticleRenderMode,
    ParticleSimulationBackend, ParticleSimulationSpace, ParticleSortMode,
    ParticleSubEmitterTrigger, ParticleTextureSheetPlaybackMode, ParticleVectorFieldMode,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ParticleModuleStage {
    Spawn,
    Initialize,
    Update,
    Render,
    Event,
    Simulation,
}

impl ParticleModuleStage {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            ParticleModuleStage::Spawn => "spawn",
            ParticleModuleStage::Initialize => "initialize",
            ParticleModuleStage::Update => "update",
            ParticleModuleStage::Render => "render",
            ParticleModuleStage::Event => "event",
            ParticleModuleStage::Simulation => "simulation",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "spawn" => Some(ParticleModuleStage::Spawn),
            "initialize" => Some(ParticleModuleStage::Initialize),
            "update" => Some(ParticleModuleStage::Update),
            "render" => Some(ParticleModuleStage::Render),
            "event" => Some(ParticleModuleStage::Event),
            "simulation" => Some(ParticleModuleStage::Simulation),
            _ => None,
        }
    }

    pub const ALL: [ParticleModuleStage; 6] = [
        ParticleModuleStage::Spawn,
        ParticleModuleStage::Initialize,
        ParticleModuleStage::Update,
        ParticleModuleStage::Render,
        ParticleModuleStage::Event,
        ParticleModuleStage::Simulation,
    ];
}

impl Serialize for ParticleModuleStage {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for ParticleModuleStage {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        ParticleModuleStage::from_raw_value(&value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown module stage: {value}")))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ParticleModuleIssueSeverity {
    Info,
    Warning,
    Error,
}

impl ParticleModuleIssueSeverity {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            ParticleModuleIssueSeverity::Info => "info",
            ParticleModuleIssueSeverity::Warning => "warning",
            ParticleModuleIssueSeverity::Error => "error",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "info" => Some(ParticleModuleIssueSeverity::Info),
            "warning" => Some(ParticleModuleIssueSeverity::Warning),
            "error" => Some(ParticleModuleIssueSeverity::Error),
            _ => None,
        }
    }

    pub const ALL: [ParticleModuleIssueSeverity; 3] = [
        ParticleModuleIssueSeverity::Info,
        ParticleModuleIssueSeverity::Warning,
        ParticleModuleIssueSeverity::Error,
    ];
}

impl Serialize for ParticleModuleIssueSeverity {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for ParticleModuleIssueSeverity {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        ParticleModuleIssueSeverity::from_raw_value(&value).ok_or_else(|| {
            serde::de::Error::custom(format!("Unknown module issue severity: {value}"))
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParticleModuleIssue {
    #[serde(rename = "moduleID")]
    pub module_id: String,
    pub severity: ParticleModuleIssueSeverity,
    pub code: String,
    pub message: String,
}

impl ParticleModuleIssue {
    pub fn new(
        module_id: impl Into<String>,
        severity: ParticleModuleIssueSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        ParticleModuleIssue {
            module_id: module_id.into(),
            severity,
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParticleModuleStack {
    pub version: i64,
    pub modules: Vec<ParticleEmitterModule>,
}

impl ParticleModuleStack {
    pub const CURRENT_VERSION: i64 = 1;

    pub const DEFAULT_MODULE_IDS: [&'static str; 11] = [
        "emission",
        "shape",
        "velocity",
        "forces",
        "collision",
        "appearance",
        "textureSheet",
        "renderer",
        "trails",
        "subEmitters",
        "gpuSimulation",
    ];

    pub fn new(version: i64, modules: Vec<ParticleEmitterModule>) -> Self {
        ParticleModuleStack {
            version: version.max(1),
            modules,
        }
    }

    /// `init(emitter:)` — the canonical module list for an emitter's settings.
    pub fn from_emitter(emitter: &ParticleEmitter) -> Self {
        ParticleModuleStack::new(
            Self::CURRENT_VERSION,
            vec![
                ParticleEmitterModule::new(
                    "emission",
                    ParticleModuleStage::Spawn,
                    "Emission",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Emission(emitter.settings.emission.clone()),
                ),
                ParticleEmitterModule::new(
                    "shape",
                    ParticleModuleStage::Spawn,
                    "Shape",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Shape(emitter.settings.shape.clone()),
                ),
                ParticleEmitterModule::new(
                    "velocity",
                    ParticleModuleStage::Initialize,
                    "Velocity",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Velocity(emitter.settings.velocity.clone()),
                ),
                ParticleEmitterModule::new(
                    "forces",
                    ParticleModuleStage::Update,
                    "Forces",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Forces(emitter.settings.forces.clone()),
                ),
                ParticleEmitterModule::new(
                    "collision",
                    ParticleModuleStage::Update,
                    "Collision",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Collision(emitter.settings.collision.clone()),
                ),
                ParticleEmitterModule::new(
                    "appearance",
                    ParticleModuleStage::Initialize,
                    "Appearance",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Appearance(emitter.settings.appearance.clone()),
                ),
                ParticleEmitterModule::new(
                    "textureSheet",
                    ParticleModuleStage::Render,
                    "Texture Sheet",
                    true,
                    false,
                    ParticleEmitterModuleSettings::TextureSheet(
                        emitter.settings.texture_sheet.clone(),
                    ),
                ),
                ParticleEmitterModule::new(
                    "renderer",
                    ParticleModuleStage::Render,
                    "Renderer",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Renderer(emitter.settings.renderer.clone()),
                ),
                ParticleEmitterModule::new(
                    "trails",
                    ParticleModuleStage::Render,
                    "Trails",
                    true,
                    false,
                    ParticleEmitterModuleSettings::Trails(emitter.settings.trails.clone()),
                ),
                ParticleEmitterModule::new(
                    "subEmitters",
                    ParticleModuleStage::Event,
                    "Sub-Emitters",
                    true,
                    false,
                    ParticleEmitterModuleSettings::SubEmitters(
                        emitter.settings.sub_emitters.clone(),
                    ),
                ),
                ParticleEmitterModule::new(
                    "gpuSimulation",
                    ParticleModuleStage::Simulation,
                    "GPU Simulation",
                    true,
                    false,
                    ParticleEmitterModuleSettings::GpuSimulation(
                        emitter.settings.gpu_simulation.clone(),
                    ),
                ),
            ],
        )
    }

    /// `init(emitter:preserving:)` — keeps the authored order and disabled
    /// payloads while refreshing enabled modules from the typed settings.
    pub fn from_emitter_preserving_template(
        emitter: &ParticleEmitter,
        template: Option<&ParticleModuleStack>,
    ) -> Self {
        let current = ParticleModuleStack::from_emitter(emitter);
        let Some(template) = template else {
            return current;
        };

        let current_by_id: HashMap<&str, &ParticleEmitterModule> = current
            .modules
            .iter()
            .map(|module| (module.id.as_str(), module))
            .collect();

        let mut used_ids: HashSet<String> = HashSet::new();
        let mut modules: Vec<ParticleEmitterModule> =
            Vec::with_capacity(template.modules.len().max(current.modules.len()));

        for authored in &template.modules {
            match current_by_id.get(authored.id.as_str()) {
                Some(refreshed) => {
                    let mut refreshed = (**refreshed).clone();
                    refreshed.is_enabled = authored.is_enabled;
                    refreshed.is_expanded = authored.is_expanded;
                    if !authored.is_enabled {
                        refreshed.settings = authored.settings.clone();
                    }
                    modules.push(refreshed);
                    used_ids.insert(authored.id.clone());
                }
                None => {
                    modules.push(authored.clone());
                    used_ids.insert(authored.id.clone());
                }
            }
        }

        for module in &current.modules {
            if !used_ids.contains(&module.id) {
                modules.push(module.clone());
            }
        }

        ParticleModuleStack::new(template.version, modules)
    }

    pub fn move_module(&mut self, source_index: usize, destination_index: usize) {
        if source_index >= self.modules.len()
            || destination_index >= self.modules.len()
            || source_index == destination_index
        {
            return;
        }
        let module = self.modules.remove(source_index);
        self.modules.insert(destination_index, module);
    }

    pub fn reset_authoring_state(&mut self) {
        let order: HashMap<&str, usize> = Self::DEFAULT_MODULE_IDS
            .iter()
            .enumerate()
            .map(|(index, id)| (*id, index))
            .collect();
        self.modules.sort_by(|lhs, rhs| {
            let lhs_order = order.get(lhs.id.as_str()).copied().unwrap_or(usize::MAX);
            let rhs_order = order.get(rhs.id.as_str()).copied().unwrap_or(usize::MAX);
            if lhs_order != rhs_order {
                return lhs_order.cmp(&rhs_order);
            }
            lhs.id.cmp(&rhs.id)
        });
        for module in &mut self.modules {
            module.is_enabled = true;
            module.is_expanded = false;
        }
    }

    pub fn reset_module_settings(&mut self, module_id: &str) {
        let Some(index) = self
            .modules
            .iter()
            .position(|module| module.id == module_id)
        else {
            return;
        };
        let Some(mut default_module) = Self::default_module(module_id) else {
            return;
        };
        default_module.is_enabled = self.modules[index].is_enabled;
        default_module.is_expanded = self.modules[index].is_expanded;
        self.modules[index] = default_module;
    }

    pub fn module_settings_differ_from_default(&self, module_id: &str) -> bool {
        let Some(module) = self.modules.iter().find(|module| module.id == module_id) else {
            return false;
        };
        let Some(mut default_module) = Self::default_module(module_id) else {
            return false;
        };
        default_module.is_enabled = module.is_enabled;
        default_module.is_expanded = module.is_expanded;
        *module != default_module
    }

    pub fn modified_module_ids(&self) -> Vec<String> {
        self.modules
            .iter()
            .filter(|module| self.module_settings_differ_from_default(&module.id))
            .map(|module| module.id.clone())
            .collect()
    }

    pub fn expanded_module_ids(&self) -> Vec<String> {
        self.modules
            .iter()
            .filter(|module| module.is_expanded)
            .map(|module| module.id.clone())
            .collect()
    }

    pub fn collapse_all_modules(&mut self) {
        for module in &mut self.modules {
            module.is_expanded = false;
        }
    }

    pub fn expand_modules(
        &mut self,
        module_ids: impl IntoIterator<Item = String>,
        collapse_others: bool,
    ) {
        let target_ids: HashSet<String> = module_ids.into_iter().collect();
        if target_ids.is_empty() && !collapse_others {
            return;
        }
        for module in &mut self.modules {
            if target_ids.contains(&module.id) {
                module.is_expanded = true;
            } else if collapse_others {
                module.is_expanded = false;
            }
        }
    }

    pub fn expand_modified_modules(&mut self, collapse_others: bool) {
        self.expand_modules(self.modified_module_ids(), collapse_others);
    }

    pub fn expand_modules_with_validation_issues(&mut self, collapse_others: bool) -> Vec<String> {
        let module_ids: Vec<String> = self
            .validation_issues()
            .into_iter()
            .map(|issue| issue.module_id)
            .collect();
        self.expand_modules(module_ids, collapse_others);
        self.expanded_module_ids()
    }

    fn default_module(module_id: &str) -> Option<ParticleEmitterModule> {
        ParticleModuleStack::from_emitter(&ParticleEmitter::default())
            .modules
            .into_iter()
            .find(|module| module.id == module_id)
    }
}

impl Default for ParticleModuleStack {
    fn default() -> Self {
        ParticleModuleStack::new(ParticleModuleStack::CURRENT_VERSION, Vec::new())
    }
}

impl Serialize for ParticleModuleStack {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("ParticleModuleStack", 2)?;
        state.serialize_field("version", &self.version)?;
        state.serialize_field("modules", &self.modules)?;
        state.end()
    }
}

impl<'de> Deserialize<'de> for ParticleModuleStack {
    /// Swift's synthesized decoding does not run `init(version:modules:)`, so the
    /// stored version is kept as written.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            version: i64,
            modules: Vec<ParticleEmitterModule>,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(ParticleModuleStack {
            version: raw.version,
            modules: raw.modules,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParticleEmitterModule {
    pub id: String,
    pub stage: ParticleModuleStage,
    pub display_name: String,
    pub is_enabled: bool,
    pub is_expanded: bool,
    pub settings: ParticleEmitterModuleSettings,
}

impl ParticleEmitterModule {
    pub fn new(
        id: impl Into<String>,
        stage: ParticleModuleStage,
        display_name: impl Into<String>,
        is_enabled: bool,
        is_expanded: bool,
        settings: ParticleEmitterModuleSettings,
    ) -> Self {
        ParticleEmitterModule {
            id: id.into(),
            stage,
            display_name: display_name.into(),
            is_enabled,
            is_expanded,
            settings,
        }
    }

    pub fn validation_issues(&self) -> Vec<ParticleModuleIssue> {
        if !self.is_enabled {
            return Vec::new();
        }
        self.settings.validation_issues(&self.id)
    }
}

impl Serialize for ParticleEmitterModule {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("ParticleEmitterModule", 6)?;
        state.serialize_field("id", &self.id)?;
        state.serialize_field("stage", &self.stage)?;
        state.serialize_field("displayName", &self.display_name)?;
        state.serialize_field("isEnabled", &self.is_enabled)?;
        state.serialize_field("isExpanded", &self.is_expanded)?;
        state.serialize_field("settings", &self.settings)?;
        state.end()
    }
}

impl<'de> Deserialize<'de> for ParticleEmitterModule {
    /// Missing authoring flags fall back to enabled and collapsed.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            id: String,
            stage: ParticleModuleStage,
            display_name: String,
            #[serde(default)]
            is_enabled: Option<bool>,
            #[serde(default)]
            is_expanded: Option<bool>,
            settings: ParticleEmitterModuleSettings,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(ParticleEmitterModule {
            id: raw.id,
            stage: raw.stage,
            display_name: raw.display_name,
            is_enabled: raw.is_enabled.unwrap_or(true),
            is_expanded: raw.is_expanded.unwrap_or(false),
            settings: raw.settings,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "camelCase")]
pub enum ParticleEmitterModuleSettings {
    Emission(ParticleEmissionModule),
    Shape(ParticleShapeModule),
    Velocity(ParticleVelocityModule),
    Forces(ParticleForcesModule),
    Collision(ParticleCollisionModule),
    Appearance(ParticleAppearanceModule),
    TextureSheet(ParticleTextureSheetModule),
    Renderer(ParticleRendererModule),
    Trails(ParticleTrailsModule),
    SubEmitters(ParticleSubEmittersModule),
    GpuSimulation(ParticleGPUSimulationModule),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleEmissionModule {
    pub is_emitting: bool,
    pub looping: bool,
    pub duration: f32,
    pub simulation_speed: f32,
    pub prewarm_time: f32,
    pub prewarm_step: f32,
    pub emission_rate: f32,
    pub emission_rate_curve: ParticleCurve,
    pub distance_emission_rate: f32,
    pub distance_emission_rate_curve: ParticleCurve,
    pub burst_count: i64,
    pub burst_interval: f32,
    pub max_particles: i64,
    pub max_spawned_particles_per_frame: i64,
    pub max_rendered_particles: i64,
    pub seed: u64,
}

impl ParticleEmissionModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.duration = self.duration.max(0.0);
        self.simulation_speed = self.simulation_speed.max(0.0);
        self.prewarm_time = self.prewarm_time.max(0.0);
        self.prewarm_step = self.prewarm_step.max(1.0 / 240.0);
        self.emission_rate = self.emission_rate.max(0.0);
        self.distance_emission_rate = self.distance_emission_rate.max(0.0);
        self.burst_count = self.burst_count.max(0);
        self.burst_interval = self.burst_interval.max(0.0);
        self.max_particles = self.max_particles.max(0);
        self.max_spawned_particles_per_frame = self.max_spawned_particles_per_frame.max(0);
        self.max_rendered_particles = self.max_rendered_particles.max(0);
    }
}

impl Default for ParticleEmissionModule {
    fn default() -> Self {
        ParticleEmissionModule {
            is_emitting: true,
            looping: true,
            duration: 0.0,
            simulation_speed: 1.0,
            prewarm_time: 0.0,
            prewarm_step: 1.0 / 30.0,
            emission_rate: 10.0,
            emission_rate_curve: ParticleCurve::Constant(1.0),
            distance_emission_rate: 0.0,
            distance_emission_rate_curve: ParticleCurve::Constant(1.0),
            burst_count: 0,
            burst_interval: 0.0,
            max_particles: 256,
            max_spawned_particles_per_frame: 0,
            max_rendered_particles: 0,
            seed: 0x9E37_79B9,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleShapeModule {
    pub origin_offset: Float3,
    pub spawn_radius: f32,
    pub emission_shape: ParticleEmissionShape,
    pub box_half_extents: Float3,
    pub cone_radius: f32,
    pub cone_height: f32,
}

impl ParticleShapeModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.spawn_radius = self.spawn_radius.max(0.0);
        self.box_half_extents = Float3::new(
            self.box_half_extents.x.max(0.0),
            self.box_half_extents.y.max(0.0),
            self.box_half_extents.z.max(0.0),
        );
        self.cone_radius = self.cone_radius.max(0.0);
        self.cone_height = self.cone_height.max(0.0);
    }
}

impl Default for ParticleShapeModule {
    fn default() -> Self {
        ParticleShapeModule {
            origin_offset: Float3::ZERO,
            spawn_radius: 0.0,
            emission_shape: ParticleEmissionShape::Sphere,
            box_half_extents: Float3::new(0.5, 0.5, 0.5),
            cone_radius: 0.5,
            cone_height: 1.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleVelocityModule {
    pub start_velocity: Float3,
    pub velocity_randomness: Float3,
    pub velocity_inheritance: f32,
}

impl ParticleVelocityModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.velocity_inheritance = self.velocity_inheritance.max(0.0);
    }
}

impl Default for ParticleVelocityModule {
    fn default() -> Self {
        ParticleVelocityModule {
            start_velocity: Float3::new(0.0, 1.0, 0.0),
            velocity_randomness: Float3::ZERO,
            velocity_inheritance: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleForcesModule {
    pub gravity: Float3,
    pub noise_strength: f32,
    pub noise_scale: f32,
    pub noise_speed: f32,
    pub force_mode: ParticleForceMode,
    pub force_center: Float3,
    pub force_axis: Float3,
    pub force_radius: f32,
    pub force_strength: f32,
    pub force_falloff: f32,
    pub vector_field_mode: ParticleVectorFieldMode,
    pub vector_field_direction: Float3,
    pub vector_field_strength: f32,
    pub vector_field_scale: f32,
    pub vector_field_scroll_speed: f32,
}

impl ParticleForcesModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.noise_strength = self.noise_strength.max(0.0);
        self.noise_scale = self.noise_scale.max(0.0001);
        self.noise_speed = self.noise_speed.max(0.0);
        self.force_radius = self.force_radius.max(0.0);
        self.force_falloff = self.force_falloff.max(0.0);
        self.vector_field_scale = self.vector_field_scale.max(0.0001);
        self.vector_field_scroll_speed = self.vector_field_scroll_speed.max(0.0);
    }
}

impl Default for ParticleForcesModule {
    fn default() -> Self {
        ParticleForcesModule {
            gravity: Float3::new(0.0, -9.81, 0.0),
            noise_strength: 0.0,
            noise_scale: 1.0,
            noise_speed: 1.0,
            force_mode: ParticleForceMode::None,
            force_center: Float3::ZERO,
            force_axis: Float3::new(0.0, 1.0, 0.0),
            force_radius: 0.0,
            force_strength: 0.0,
            force_falloff: 1.0,
            vector_field_mode: ParticleVectorFieldMode::None,
            vector_field_direction: Float3::new(0.0, 1.0, 0.0),
            vector_field_strength: 0.0,
            vector_field_scale: 1.0,
            vector_field_scroll_speed: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleCollisionModule {
    pub collision_mode: ParticleCollisionMode,
    pub collision_plane_y: f32,
    pub collision_restitution: f32,
    pub collision_damping: f32,
}

impl ParticleCollisionModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.collision_restitution = simd_clamp_scalar(self.collision_restitution, 0.0, 1.0);
        self.collision_damping = simd_clamp_scalar(self.collision_damping, 0.0, 1.0);
    }
}

impl Default for ParticleCollisionModule {
    fn default() -> Self {
        ParticleCollisionModule {
            collision_mode: ParticleCollisionMode::None,
            collision_plane_y: 0.0,
            collision_restitution: 0.5,
            collision_damping: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleAppearanceModule {
    pub lifetime: f32,
    pub lifetime_randomness: f32,
    pub start_size: f32,
    pub end_size: f32,
    pub size_randomness: f32,
    pub start_rotation: f32,
    pub rotation_randomness: f32,
    pub angular_velocity: f32,
    pub angular_velocity_randomness: f32,
    pub size_curve: ParticleCurve,
    pub start_color: Float4,
    pub end_color: Float4,
    pub color_curve: ParticleCurve,
    pub blend_mode: ParticleBlendMode,
}

impl ParticleAppearanceModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.lifetime = self.lifetime.max(0.0);
        self.lifetime_randomness = self.lifetime_randomness.max(0.0);
        self.size_randomness = self.size_randomness.max(0.0);
        self.rotation_randomness = self.rotation_randomness.max(0.0);
        self.angular_velocity_randomness = self.angular_velocity_randomness.max(0.0);
    }
}

impl Default for ParticleAppearanceModule {
    fn default() -> Self {
        ParticleAppearanceModule {
            lifetime: 2.0,
            lifetime_randomness: 0.0,
            start_size: 1.0,
            end_size: 0.0,
            size_randomness: 0.0,
            start_rotation: 0.0,
            rotation_randomness: 0.0,
            angular_velocity: 0.0,
            angular_velocity_randomness: 0.0,
            size_curve: ParticleCurve::Linear,
            start_color: Float4::new(1.0, 1.0, 1.0, 1.0),
            end_color: Float4::new(1.0, 1.0, 1.0, 0.0),
            color_curve: ParticleCurve::Linear,
            blend_mode: ParticleBlendMode::Alpha,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleTextureSheetModule {
    #[serde(rename = "textureAssetID", skip_serializing_if = "Option::is_none")]
    pub texture_asset_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub texture_path: Option<String>,
    pub columns: i64,
    pub rows: i64,
    pub frame_count: i64,
    pub frame_rate: f32,
    pub playback_mode: ParticleTextureSheetPlaybackMode,
    pub start_frame: i64,
    pub frame_randomness: i64,
}

impl ParticleTextureSheetModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.texture_asset_id = if self
            .texture_asset_id
            .as_ref()
            .is_some_and(|value| value.is_empty())
        {
            None
        } else {
            self.texture_asset_id.clone()
        };
        self.texture_path = if self
            .texture_path
            .as_ref()
            .is_some_and(|value| value.is_empty())
        {
            None
        } else {
            self.texture_path.clone()
        };
        self.columns = self.columns.max(1);
        self.rows = self.rows.max(1);
        self.frame_count = self.frame_count.max(1);
        self.frame_rate = self.frame_rate.max(0.0);
        self.start_frame = self.start_frame.max(0);
        self.frame_randomness = self.frame_randomness.max(0);
    }
}

impl Default for ParticleTextureSheetModule {
    fn default() -> Self {
        ParticleTextureSheetModule {
            texture_asset_id: None,
            texture_path: None,
            columns: 1,
            rows: 1,
            frame_count: 1,
            frame_rate: 0.0,
            playback_mode: ParticleTextureSheetPlaybackMode::Automatic,
            start_frame: 0,
            frame_randomness: 0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleRendererModule {
    pub render_mode: ParticleRenderMode,
    pub sort_mode: ParticleSortMode,
    pub render_sort_priority: i64,
    pub render_alignment: ParticleRenderAlignment,
    pub velocity_stretch_scale: f32,
    pub velocity_stretch_max: f32,
    pub max_render_distance: f32,
    pub render_distance_fade_range: f32,
    #[serde(rename = "renderLODStartDistance")]
    pub render_lod_start_distance: f32,
    #[serde(rename = "renderLODEndDistance")]
    pub render_lod_end_distance: f32,
    #[serde(rename = "renderLODMinParticleScale")]
    pub render_lod_min_particle_scale: f32,
    pub render_bounds_mode: ParticleRenderBoundsMode,
    pub render_bounds_radius: f32,
}

impl ParticleRendererModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.velocity_stretch_scale = self.velocity_stretch_scale.max(0.0);
        self.velocity_stretch_max = self.velocity_stretch_max.max(1.0);
        self.max_render_distance = self.max_render_distance.max(0.0);
        self.render_distance_fade_range = self.render_distance_fade_range.max(0.0);
        self.render_lod_start_distance = self.render_lod_start_distance.max(0.0);
        self.render_lod_end_distance = self.render_lod_end_distance.max(0.0);
        self.render_lod_min_particle_scale =
            simd_clamp_scalar(self.render_lod_min_particle_scale, 0.0, 1.0);
        self.render_bounds_radius = self.render_bounds_radius.max(0.0);
    }
}

impl Default for ParticleRendererModule {
    fn default() -> Self {
        ParticleRendererModule {
            render_mode: ParticleRenderMode::Billboard,
            sort_mode: ParticleSortMode::DistanceDescending,
            render_sort_priority: 0,
            render_alignment: ParticleRenderAlignment::Billboard,
            velocity_stretch_scale: 0.0,
            velocity_stretch_max: 8.0,
            max_render_distance: 0.0,
            render_distance_fade_range: 0.0,
            render_lod_start_distance: 0.0,
            render_lod_end_distance: 0.0,
            render_lod_min_particle_scale: 1.0,
            render_bounds_mode: ParticleRenderBoundsMode::Disabled,
            render_bounds_radius: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleTrailsModule {
    pub ribbon_width_scale: f32,
    pub ribbon_tail_width_scale: f32,
    pub ribbon_tail_alpha_scale: f32,
    pub ribbon_max_segment_length: f32,
    pub ribbon_join_overlap_scale: f32,
    pub ribbon_smoothing_segments: i64,
    pub ribbon_texture_tiling: f32,
    pub ribbon_texture_offset: f32,
    pub trail_length: f32,
    pub trail_segments: i64,
    pub trail_end_size_scale: f32,
    pub trail_end_alpha_scale: f32,
}

impl ParticleTrailsModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.ribbon_width_scale = self.ribbon_width_scale.max(0.0);
        self.ribbon_tail_width_scale = self.ribbon_tail_width_scale.max(0.0);
        self.ribbon_tail_alpha_scale = simd_clamp_scalar(self.ribbon_tail_alpha_scale, 0.0, 1.0);
        self.ribbon_max_segment_length = self.ribbon_max_segment_length.max(0.0);
        self.ribbon_join_overlap_scale = self.ribbon_join_overlap_scale.max(0.0);
        self.ribbon_smoothing_segments = self.ribbon_smoothing_segments.clamp(1, 16);
        self.ribbon_texture_tiling = self.ribbon_texture_tiling.max(0.0);
        self.trail_length = self.trail_length.max(0.0);
        self.trail_segments = self.trail_segments.max(0);
        self.trail_end_size_scale = self.trail_end_size_scale.max(0.0);
        self.trail_end_alpha_scale = simd_clamp_scalar(self.trail_end_alpha_scale, 0.0, 1.0);
    }
}

impl Default for ParticleTrailsModule {
    fn default() -> Self {
        ParticleTrailsModule {
            ribbon_width_scale: 1.0,
            ribbon_tail_width_scale: 1.0,
            ribbon_tail_alpha_scale: 1.0,
            ribbon_max_segment_length: 0.0,
            ribbon_join_overlap_scale: 0.0,
            ribbon_smoothing_segments: 1,
            ribbon_texture_tiling: 0.0,
            ribbon_texture_offset: 0.0,
            trail_length: 0.0,
            trail_segments: 0,
            trail_end_size_scale: 0.5,
            trail_end_alpha_scale: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleSubEmittersModule {
    pub legacy_trigger: ParticleSubEmitterTrigger,
    pub legacy_burst_count: i64,
    pub legacy_probability: f32,
    pub legacy_max_depth: i64,
    pub legacy_inherit_velocity: f32,
    pub legacy_lifetime: f32,
    pub legacy_start_velocity: Float3,
    pub legacy_velocity_randomness: Float3,
    pub legacy_start_size: f32,
    pub legacy_end_size: f32,
    pub legacy_start_color: Float4,
    pub legacy_end_color: Float4,
    pub rules: Vec<ParticleSubEmitter>,
}

impl ParticleSubEmittersModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.legacy_burst_count = self.legacy_burst_count.max(0);
        self.legacy_probability = simd_clamp_scalar(self.legacy_probability, 0.0, 1.0);
        self.legacy_max_depth = self.legacy_max_depth.max(0);
        self.legacy_inherit_velocity = self.legacy_inherit_velocity.max(0.0);
        self.legacy_lifetime = self.legacy_lifetime.max(0.0001);
        self.legacy_start_size = self.legacy_start_size.max(0.0);
        self.legacy_end_size = self.legacy_end_size.max(0.0);
        self.rules = self.rules.iter().map(repaired_sub_emitter).collect();
    }
}

impl Default for ParticleSubEmittersModule {
    fn default() -> Self {
        ParticleSubEmittersModule {
            legacy_trigger: ParticleSubEmitterTrigger::None,
            legacy_burst_count: 0,
            legacy_probability: 1.0,
            legacy_max_depth: 1,
            legacy_inherit_velocity: 0.0,
            legacy_lifetime: 0.5,
            legacy_start_velocity: Float3::ZERO,
            legacy_velocity_randomness: Float3::ZERO,
            legacy_start_size: 0.25,
            legacy_end_size: 0.0,
            legacy_start_color: Float4::new(1.0, 1.0, 1.0, 1.0),
            legacy_end_color: Float4::new(1.0, 1.0, 1.0, 0.0),
            rules: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleGPUSimulationModule {
    pub simulation_space: ParticleSimulationSpace,
    pub simulation_backend: ParticleSimulationBackend,
    pub workgroup_size: i64,
}

impl ParticleGPUSimulationModule {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configured(configure: impl FnOnce(&mut Self)) -> Self {
        let mut module = Self::default();
        configure(&mut module);
        module
    }

    pub(crate) fn normalize(&mut self) {
        self.workgroup_size = self.workgroup_size.max(1);
    }
}

impl Default for ParticleGPUSimulationModule {
    fn default() -> Self {
        ParticleGPUSimulationModule {
            simulation_space: ParticleSimulationSpace::Local,
            simulation_backend: ParticleSimulationBackend::Cpu,
            workgroup_size: 64,
        }
    }
}

impl ParticleModuleStack {
    pub fn validation_issues(&self) -> Vec<ParticleModuleIssue> {
        let mut issues: Vec<ParticleModuleIssue> = Vec::new();
        let mut seen_ids: HashSet<&str> = HashSet::new();

        for module in &self.modules {
            if !seen_ids.insert(module.id.as_str()) {
                issues.push(ParticleModuleIssue::new(
                    module.id.clone(),
                    ParticleModuleIssueSeverity::Warning,
                    "duplicateModule",
                    format!(
                        "Duplicate module id '{}' will make authoring order ambiguous.",
                        module.id
                    ),
                ));
            }
        }

        for id in Self::DEFAULT_MODULE_IDS {
            if !seen_ids.contains(id) {
                issues.push(ParticleModuleIssue::new(
                    id,
                    ParticleModuleIssueSeverity::Warning,
                    "missingModule",
                    format!("Default module '{id}' is missing from this stack."),
                ));
            }
        }

        for module in &self.modules {
            if module.is_enabled {
                issues.extend(module.validation_issues());
            }
        }

        issues
    }

    pub fn repair_validation_issues(&mut self) {
        self.repair_module_topology();
        for index in 0..self.modules.len() {
            if self.modules[index].is_enabled {
                self.modules[index].settings.repair_validation_issues();
            }
        }
    }

    pub fn repair_validation_issues_for(&mut self, module_id: &str) {
        self.repair_module_topology();
        let Some(index) = self
            .modules
            .iter()
            .position(|module| module.id == module_id && module.is_enabled)
        else {
            return;
        };
        self.modules[index].settings.repair_validation_issues();
    }

    fn repair_module_topology(&mut self) {
        let default_modules =
            ParticleModuleStack::from_emitter(&ParticleEmitter::default()).modules;
        let defaults_by_id: HashMap<&str, &ParticleEmitterModule> = default_modules
            .iter()
            .map(|module| (module.id.as_str(), module))
            .collect();
        let default_ids: HashSet<&str> = Self::DEFAULT_MODULE_IDS.iter().copied().collect();
        let mut seen_ids: HashSet<String> = HashSet::new();
        let mut repaired: Vec<ParticleEmitterModule> =
            Vec::with_capacity(self.modules.len().max(default_modules.len()));

        for module in &self.modules {
            if !seen_ids.insert(module.id.clone()) {
                continue;
            }
            let mut normalized = module.clone();
            if default_ids.contains(module.id.as_str())
                && let Some(default_module) = defaults_by_id.get(module.id.as_str())
            {
                normalized.stage = default_module.stage;
                normalized.display_name = default_module.display_name.clone();
            }
            repaired.push(normalized);
        }

        for default_module in &default_modules {
            if !seen_ids.contains(&default_module.id) {
                repaired.push(default_module.clone());
                seen_ids.insert(default_module.id.clone());
            }
        }

        self.version = Self::CURRENT_VERSION;
        self.modules = repaired;
    }
}

impl ParticleEmitterModuleSettings {
    fn validation_issues(&self, module_id: &str) -> Vec<ParticleModuleIssue> {
        match self {
            ParticleEmitterModuleSettings::Emission(settings) => {
                validate_emission(settings, module_id)
            }
            ParticleEmitterModuleSettings::Shape(settings) => validate_shape(settings, module_id),
            ParticleEmitterModuleSettings::Velocity(settings) => {
                validate_velocity(settings, module_id)
            }
            ParticleEmitterModuleSettings::Forces(settings) => validate_forces(settings, module_id),
            ParticleEmitterModuleSettings::Collision(settings) => {
                validate_collision(settings, module_id)
            }
            ParticleEmitterModuleSettings::Appearance(settings) => {
                validate_appearance(settings, module_id)
            }
            ParticleEmitterModuleSettings::TextureSheet(settings) => {
                validate_texture_sheet(settings, module_id)
            }
            ParticleEmitterModuleSettings::Renderer(settings) => {
                validate_renderer(settings, module_id)
            }
            ParticleEmitterModuleSettings::Trails(settings) => validate_trails(settings, module_id),
            ParticleEmitterModuleSettings::SubEmitters(settings) => {
                validate_sub_emitters(settings, module_id)
            }
            ParticleEmitterModuleSettings::GpuSimulation(settings) => {
                validate_gpu_simulation(settings, module_id)
            }
        }
    }

    fn repair_validation_issues(&mut self) {
        match self {
            ParticleEmitterModuleSettings::Emission(settings) => {
                settings.simulation_speed = settings.simulation_speed.max(0.0);
                settings.max_particles = settings.max_particles.max(1);
                settings.max_spawned_particles_per_frame =
                    settings.max_spawned_particles_per_frame.max(0);
                settings.max_rendered_particles = settings
                    .max_rendered_particles
                    .min(settings.max_particles)
                    .max(0);
                settings.prewarm_time = settings.prewarm_time.max(0.0);
                if settings.prewarm_time > 0.0 {
                    settings.prewarm_step = settings.prewarm_step.max(1.0 / 240.0);
                }
                settings.emission_rate = settings.emission_rate.max(0.0);
                settings.distance_emission_rate = settings.distance_emission_rate.max(0.0);
                settings.burst_count = settings.burst_count.max(0);
                settings.burst_interval = settings.burst_interval.max(0.0);
            }
            ParticleEmitterModuleSettings::Shape(settings) => {
                settings.spawn_radius = settings.spawn_radius.max(0.0);
                settings.box_half_extents = Float3::new(
                    settings.box_half_extents.x.max(0.0001),
                    settings.box_half_extents.y.max(0.0001),
                    settings.box_half_extents.z.max(0.0001),
                );
                settings.cone_radius = settings.cone_radius.max(0.0001);
                settings.cone_height = settings.cone_height.max(0.0001);
            }
            ParticleEmitterModuleSettings::Velocity(settings) => {
                settings.velocity_inheritance = settings.velocity_inheritance.max(0.0);
            }
            ParticleEmitterModuleSettings::Forces(settings) => {
                settings.noise_strength = settings.noise_strength.max(0.0);
                settings.noise_scale = settings.noise_scale.max(0.0001);
                settings.noise_speed = settings.noise_speed.max(0.0);
                settings.force_radius = settings.force_radius.max(0.0);
                settings.force_falloff = settings.force_falloff.max(0.0);
                settings.vector_field_scale = settings.vector_field_scale.max(0.0001);
                settings.vector_field_scroll_speed = settings.vector_field_scroll_speed.max(0.0);
            }
            ParticleEmitterModuleSettings::Collision(settings) => {
                settings.collision_restitution =
                    simd_clamp_scalar(settings.collision_restitution, 0.0, 1.0);
                settings.collision_damping =
                    simd_clamp_scalar(settings.collision_damping, 0.0, 1.0);
            }
            ParticleEmitterModuleSettings::Appearance(settings) => {
                settings.lifetime = settings.lifetime.max(0.0001);
                settings.lifetime_randomness = settings.lifetime_randomness.max(0.0);
                settings.start_size = settings.start_size.max(0.0);
                settings.end_size = settings.end_size.max(0.0);
                settings.size_randomness = settings.size_randomness.max(0.0);
                settings.rotation_randomness = settings.rotation_randomness.max(0.0);
                settings.angular_velocity_randomness =
                    settings.angular_velocity_randomness.max(0.0);
            }
            ParticleEmitterModuleSettings::TextureSheet(settings) => {
                settings.columns = settings.columns.max(1);
                settings.rows = settings.rows.max(1);
                let cell_count = 1.max(settings.columns * settings.rows);
                settings.frame_count = settings.frame_count.max(1).min(cell_count);
                settings.frame_rate = settings.frame_rate.max(0.0);
                settings.start_frame = settings.start_frame.max(0).min(cell_count - 1);
                settings.frame_randomness = settings.frame_randomness.max(0);
            }
            ParticleEmitterModuleSettings::Renderer(settings) => {
                settings.velocity_stretch_scale = settings.velocity_stretch_scale.max(0.0);
                settings.velocity_stretch_max = settings.velocity_stretch_max.max(1.0);
                settings.max_render_distance = settings.max_render_distance.max(0.0);
                settings.render_distance_fade_range = settings.render_distance_fade_range.max(0.0);
                if settings.max_render_distance > 0.0 {
                    settings.render_distance_fade_range = settings
                        .render_distance_fade_range
                        .min(settings.max_render_distance);
                }
                settings.render_lod_start_distance = settings.render_lod_start_distance.max(0.0);
                settings.render_lod_end_distance = settings.render_lod_end_distance.max(0.0);
                if settings.render_lod_end_distance > 0.0
                    && settings.render_lod_start_distance > settings.render_lod_end_distance
                {
                    settings.render_lod_start_distance = settings.render_lod_end_distance;
                }
                settings.render_lod_min_particle_scale =
                    simd_clamp_scalar(settings.render_lod_min_particle_scale, 0.0, 1.0);
                if settings.render_bounds_mode != ParticleRenderBoundsMode::Disabled {
                    settings.render_bounds_radius = settings.render_bounds_radius.max(0.0001);
                } else {
                    settings.render_bounds_radius = settings.render_bounds_radius.max(0.0);
                }
            }
            ParticleEmitterModuleSettings::Trails(settings) => {
                settings.ribbon_width_scale = settings.ribbon_width_scale.max(0.0);
                settings.ribbon_tail_width_scale = settings.ribbon_tail_width_scale.max(0.0);
                settings.ribbon_tail_alpha_scale =
                    simd_clamp_scalar(settings.ribbon_tail_alpha_scale, 0.0, 1.0);
                settings.ribbon_max_segment_length = settings.ribbon_max_segment_length.max(0.0);
                settings.ribbon_join_overlap_scale = settings.ribbon_join_overlap_scale.max(0.0);
                settings.ribbon_smoothing_segments =
                    settings.ribbon_smoothing_segments.clamp(1, 16);
                settings.ribbon_texture_tiling = settings.ribbon_texture_tiling.max(0.0);
                settings.trail_length = settings.trail_length.max(0.0);
                if settings.trail_length > 0.0 {
                    settings.trail_segments = settings.trail_segments.max(1);
                } else {
                    settings.trail_segments = settings.trail_segments.max(0);
                }
                settings.trail_end_size_scale = settings.trail_end_size_scale.max(0.0);
                settings.trail_end_alpha_scale =
                    simd_clamp_scalar(settings.trail_end_alpha_scale, 0.0, 1.0);
            }
            ParticleEmitterModuleSettings::SubEmitters(settings) => {
                settings.legacy_burst_count =
                    if settings.legacy_trigger == ParticleSubEmitterTrigger::None {
                        settings.legacy_burst_count.max(0)
                    } else {
                        settings.legacy_burst_count.max(1)
                    };
                settings.legacy_probability =
                    simd_clamp_scalar(settings.legacy_probability, 0.0, 1.0);
                settings.legacy_max_depth = settings.legacy_max_depth.max(0);
                settings.legacy_inherit_velocity = settings.legacy_inherit_velocity.max(0.0);
                settings.legacy_lifetime = settings.legacy_lifetime.max(0.0001);
                settings.legacy_start_size = settings.legacy_start_size.max(0.0);
                settings.legacy_end_size = settings.legacy_end_size.max(0.0);
                settings.rules = settings.rules.iter().map(repaired_sub_emitter).collect();
            }
            ParticleEmitterModuleSettings::GpuSimulation(settings) => {
                settings.workgroup_size = settings
                    .workgroup_size
                    .clamp(1, ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE);
            }
        }
    }
}

fn repaired_sub_emitter(rule: &ParticleSubEmitter) -> ParticleSubEmitter {
    ParticleSubEmitter::new(
        rule.trigger,
        rule.burst_count,
        simd_clamp_scalar(rule.probability, 0.0, 1.0),
        rule.max_depth.max(0),
        rule.inherit_velocity.max(0.0),
        rule.lifetime.max(0.0001),
        rule.start_velocity,
        rule.velocity_randomness,
        rule.start_size.max(0.0),
        rule.end_size.max(0.0),
        rule.start_color,
        rule.end_color,
    )
}

impl ParticleGPUSimulationPlan {
    fn unsupported_reason_summary(&self) -> String {
        self.unsupported_reasons
            .iter()
            .map(|reason| reason.display_name())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

impl ParticleGPUSimulationUnsupportedReason {
    fn display_name(&self) -> &'static str {
        match self {
            ParticleGPUSimulationUnsupportedReason::BackendCpu => "CPU backend",
            ParticleGPUSimulationUnsupportedReason::NoParticleCapacity => "no particle capacity",
            ParticleGPUSimulationUnsupportedReason::EventSubEmitters => "event sub-emitters",
            ParticleGPUSimulationUnsupportedReason::DistanceEmission => "distance emission",
            ParticleGPUSimulationUnsupportedReason::Noise => "noise",
            ParticleGPUSimulationUnsupportedReason::ForceFields => "force fields",
            ParticleGPUSimulationUnsupportedReason::Collisions => "collisions",
            ParticleGPUSimulationUnsupportedReason::AngularVelocity => "angular velocity",
        }
    }
}

fn issue(
    module_id: &str,
    severity: ParticleModuleIssueSeverity,
    code: &str,
    message: impl Into<String>,
) -> ParticleModuleIssue {
    ParticleModuleIssue::new(module_id, severity, code, message)
}

fn validate_emission(
    settings: &ParticleEmissionModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.max_particles <= 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "noParticleCapacity",
            "Max particles must be greater than zero.",
        ));
    }
    if settings.simulation_speed < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeSimulationSpeed",
            "Simulation speed is negative and will be clamped.",
        ));
    }
    if settings.is_emitting
        && settings.emission_rate <= 0.0
        && settings.distance_emission_rate <= 0.0
        && settings.burst_count <= 0
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "noSpawnSource",
            "Emitter is enabled but has no continuous, distance, or burst spawn source.",
        ));
    }
    if settings.max_particles > 0 && settings.max_rendered_particles > settings.max_particles {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Info,
            "renderCapExceedsCapacity",
            "Max rendered particles exceeds simulation capacity and will have no extra effect.",
        ));
    }
    if settings.max_spawned_particles_per_frame < 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeSpawnBudget",
            "Max spawned particles per frame is negative and will be clamped.",
        ));
    }
    if settings.prewarm_time > 0.0 && settings.prewarm_step <= 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidPrewarmStep",
            "Prewarm step must be greater than zero.",
        ));
    }
    issues
}

fn validate_shape(settings: &ParticleShapeModule, module_id: &str) -> Vec<ParticleModuleIssue> {
    match settings.emission_shape {
        ParticleEmissionShape::Sphere if settings.spawn_radius < 0.0 => vec![issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeSpawnRadius",
            "Sphere radius is negative and will be clamped.",
        )],
        ParticleEmissionShape::Box
            if settings.box_half_extents.x <= 0.0
                || settings.box_half_extents.y <= 0.0
                || settings.box_half_extents.z <= 0.0 =>
        {
            vec![issue(
                module_id,
                ParticleModuleIssueSeverity::Warning,
                "invalidBoxExtents",
                "Box half extents should be greater than zero on every axis.",
            )]
        }
        ParticleEmissionShape::Cone
            if settings.cone_radius <= 0.0 || settings.cone_height <= 0.0 =>
        {
            vec![issue(
                module_id,
                ParticleModuleIssueSeverity::Warning,
                "invalidConeShape",
                "Cone radius and height should be greater than zero.",
            )]
        }
        _ => Vec::new(),
    }
}

fn validate_velocity(
    settings: &ParticleVelocityModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    if settings.velocity_inheritance < 0.0 {
        vec![issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeVelocityInheritance",
            "Velocity inheritance is negative and will be clamped.",
        )]
    } else {
        Vec::new()
    }
}

fn validate_forces(settings: &ParticleForcesModule, module_id: &str) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.noise_strength > 0.0 && settings.noise_scale <= 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidNoiseScale",
            "Noise scale must be greater than zero when noise is active.",
        ));
    }
    if settings.force_mode != ParticleForceMode::None && settings.force_radius <= 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "invalidForceRadius",
            "Force radius should be greater than zero when a force field is active.",
        ));
    }
    if settings.force_mode != ParticleForceMode::None && settings.force_falloff < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeForceFalloff",
            "Force falloff is negative and will be clamped.",
        ));
    }
    if settings.vector_field_mode != ParticleVectorFieldMode::None
        && settings.vector_field_scale <= 0.0
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidVectorFieldScale",
            "Vector field scale must be greater than zero when a vector field is active.",
        ));
    }
    issues
}

fn validate_collision(
    settings: &ParticleCollisionModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.collision_restitution < 0.0 || settings.collision_restitution > 1.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "restitutionOutOfRange",
            "Restitution should be between 0 and 1.",
        ));
    }
    if settings.collision_damping < 0.0 || settings.collision_damping > 1.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "dampingOutOfRange",
            "Damping should be between 0 and 1.",
        ));
    }
    issues
}

fn validate_appearance(
    settings: &ParticleAppearanceModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.lifetime <= 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidLifetime",
            "Particle lifetime must be greater than zero.",
        ));
    }
    if settings.start_size < 0.0 || settings.end_size < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeParticleSize",
            "Particle sizes should not be negative.",
        ));
    }
    if settings.size_randomness < 0.0 || settings.lifetime_randomness < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeRandomness",
            "Randomness values should not be negative.",
        ));
    }
    issues
}

fn validate_texture_sheet(
    settings: &ParticleTextureSheetModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    let columns = settings.columns.max(0);
    let rows = settings.rows.max(0);
    let cell_count = columns * rows;
    if settings.columns <= 0 || settings.rows <= 0 || settings.frame_count <= 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidTextureSheet",
            "Texture sheet columns, rows, and frame count must be greater than zero.",
        ));
    }
    if cell_count > 0 && settings.frame_count > cell_count {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "frameCountExceedsCells",
            "Frame count exceeds the number of cells in the texture sheet.",
        ));
    }
    if cell_count > 0 && settings.start_frame >= cell_count {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "startFrameOutOfRange",
            "Start frame is outside the texture sheet cell range.",
        ));
    }
    if settings.frame_randomness < 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeFrameRandomness",
            "Frame randomness is negative and will be clamped.",
        ));
    }
    issues
}

fn validate_renderer(
    settings: &ParticleRendererModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.velocity_stretch_scale < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeVelocityStretch",
            "Velocity stretch scale is negative and will be clamped.",
        ));
    }
    if settings.render_lod_end_distance > 0.0
        && settings.render_lod_start_distance > settings.render_lod_end_distance
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "invalidLODRange",
            "LOD start distance should not exceed LOD end distance.",
        ));
    }
    if settings.render_lod_start_distance < 0.0 || settings.render_lod_end_distance < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeLODDistance",
            "LOD distances should not be negative.",
        ));
    }
    if settings.render_lod_min_particle_scale < 0.0 || settings.render_lod_min_particle_scale > 1.0
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "lodScaleOutOfRange",
            "LOD minimum particle scale should be between 0 and 1.",
        ));
    }
    if settings.max_render_distance < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeMaxRenderDistance",
            "Max render distance should not be negative.",
        ));
    }
    if settings.render_distance_fade_range < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeFadeRange",
            "Distance fade range should not be negative.",
        ));
    }
    if settings.max_render_distance > 0.0
        && settings.render_distance_fade_range > settings.max_render_distance
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "fadeRangeExceedsDistance",
            "Distance fade range exceeds max render distance.",
        ));
    }
    if settings.render_bounds_radius < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeRenderBoundsRadius",
            "Render bounds radius should not be negative.",
        ));
    }
    if settings.render_bounds_mode != ParticleRenderBoundsMode::Disabled
        && settings.render_bounds_radius <= 0.0
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "invalidRenderBounds",
            "Explicit render bounds need a radius greater than zero.",
        ));
    }
    if settings.velocity_stretch_scale > 0.0 && settings.velocity_stretch_max <= 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidVelocityStretch",
            "Velocity stretch max must be greater than zero.",
        ));
    }
    issues
}

fn validate_trails(settings: &ParticleTrailsModule, module_id: &str) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.trail_length < 0.0 || settings.trail_segments < 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeTrailSettings",
            "Trail length and segment count should not be negative.",
        ));
    }
    if settings.trail_length > 0.0 && settings.trail_segments <= 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "trailWithoutSamples",
            "Trail length is active but trail segments is zero.",
        ));
    }
    if settings.ribbon_smoothing_segments <= 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "invalidRibbonSmoothing",
            "Ribbon smoothing segments should be at least one.",
        ));
    }
    if settings.ribbon_tail_alpha_scale < 0.0 || settings.ribbon_tail_alpha_scale > 1.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "tailAlphaOutOfRange",
            "Ribbon tail alpha should be between 0 and 1.",
        ));
    }
    if settings.ribbon_width_scale < 0.0 || settings.ribbon_tail_width_scale < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeRibbonWidth",
            "Ribbon width scales should not be negative.",
        ));
    }
    if settings.ribbon_max_segment_length < 0.0 || settings.ribbon_join_overlap_scale < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeRibbonSegment",
            "Ribbon segment and join settings should not be negative.",
        ));
    }
    if settings.ribbon_texture_tiling < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeRibbonTiling",
            "Ribbon texture tiling should not be negative.",
        ));
    }
    if settings.trail_end_size_scale < 0.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "negativeTrailEndSize",
            "Trail end size scale should not be negative.",
        ));
    }
    if settings.trail_end_alpha_scale < 0.0 || settings.trail_end_alpha_scale > 1.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "trailEndAlphaOutOfRange",
            "Trail end alpha should be between 0 and 1.",
        ));
    }
    issues
}

fn validate_sub_emitters(
    settings: &ParticleSubEmittersModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.legacy_trigger != ParticleSubEmitterTrigger::None
        && settings.legacy_burst_count <= 0
    {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "legacySubEmitterNoBurst",
            "Legacy sub-emitter trigger is active but burst count is zero.",
        ));
    }
    if settings.legacy_probability < 0.0 || settings.legacy_probability > 1.0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "legacyProbabilityOutOfRange",
            "Legacy sub-emitter probability should be between 0 and 1.",
        ));
    }
    for (index, rule) in settings.rules.iter().enumerate() {
        if rule.trigger != ParticleSubEmitterTrigger::None && rule.burst_count <= 0 {
            issues.push(issue(
                module_id,
                ParticleModuleIssueSeverity::Warning,
                "subEmitterNoBurst",
                format!(
                    "Sub-emitter rule {} has a trigger but no burst count.",
                    index + 1
                ),
            ));
        }
        if rule.probability < 0.0 || rule.probability > 1.0 {
            issues.push(issue(
                module_id,
                ParticleModuleIssueSeverity::Warning,
                "subEmitterProbabilityOutOfRange",
                format!(
                    "Sub-emitter rule {} probability should be between 0 and 1.",
                    index + 1
                ),
            ));
        }
        if rule.lifetime <= 0.0 {
            issues.push(issue(
                module_id,
                ParticleModuleIssueSeverity::Error,
                "subEmitterInvalidLifetime",
                format!(
                    "Sub-emitter rule {} lifetime must be greater than zero.",
                    index + 1
                ),
            ));
        }
    }
    issues
}

fn validate_gpu_simulation(
    settings: &ParticleGPUSimulationModule,
    module_id: &str,
) -> Vec<ParticleModuleIssue> {
    let mut issues: Vec<ParticleModuleIssue> = Vec::new();
    if settings.workgroup_size <= 0 {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Error,
            "invalidGPUWorkgroup",
            "GPU workgroup size must be greater than zero.",
        ));
    } else if settings.workgroup_size > ParticleGPUSimulationPlan::MAXIMUM_WORKGROUP_SIZE {
        issues.push(issue(
            module_id,
            ParticleModuleIssueSeverity::Warning,
            "gpuWorkgroupClamped",
            "GPU workgroup size exceeds the runtime maximum and will be clamped.",
        ));
    }
    issues
}

impl ParticleEmitter {
    pub fn module_validation_issues(&self) -> Vec<ParticleModuleIssue> {
        let module_stack = self.module_stack();
        let mut issues = module_stack.validation_issues();
        let gpu_enabled = module_stack
            .modules
            .iter()
            .any(|module| module.id == "gpuSimulation" && module.is_enabled);
        if !gpu_enabled {
            return issues;
        }

        let plan = ParticleGPUSimulationPlan::new(self);
        match plan.status {
            ParticleGPUSimulationPlanStatus::Disabled
            | ParticleGPUSimulationPlanStatus::Supported => {}
            ParticleGPUSimulationPlanStatus::FallbackToCpu => {
                issues.push(ParticleModuleIssue::new(
                    "gpuSimulation",
                    ParticleModuleIssueSeverity::Warning,
                    "gpuFallbackToCPU",
                    format!(
                        "GPU simulation will fall back to CPU: {}.",
                        plan.unsupported_reason_summary()
                    ),
                ));
            }
            ParticleGPUSimulationPlanStatus::RequiredButUnsupported => {
                issues.push(ParticleModuleIssue::new(
                    "gpuSimulation",
                    ParticleModuleIssueSeverity::Error,
                    "gpuRequiredButUnsupported",
                    format!(
                        "GPU simulation is required but unsupported: {}.",
                        plan.unsupported_reason_summary()
                    ),
                ));
            }
        }
        issues
    }

    pub fn module_stack(&self) -> ParticleModuleStack {
        ParticleModuleStack::from_emitter_preserving_template(
            self,
            self.authored_module_stack.as_ref(),
        )
    }

    pub fn apply(&mut self, module_stack: ParticleModuleStack) {
        for module in &module_stack.modules {
            if !module.is_enabled {
                continue;
            }
            match &module.settings {
                ParticleEmitterModuleSettings::Emission(module_settings) => {
                    if self.settings.emission.seed != module_settings.seed {
                        self.reseed(module_settings.seed);
                    }
                    self.settings.emission = module_settings.clone();
                    self.settings.emission.normalize();
                }
                ParticleEmitterModuleSettings::Shape(module_settings) => {
                    self.settings.shape = module_settings.clone();
                    self.settings.shape.normalize();
                }
                ParticleEmitterModuleSettings::Velocity(module_settings) => {
                    self.settings.velocity = module_settings.clone();
                    self.settings.velocity.normalize();
                }
                ParticleEmitterModuleSettings::Forces(module_settings) => {
                    self.settings.forces = module_settings.clone();
                    self.settings.forces.normalize();
                }
                ParticleEmitterModuleSettings::Collision(module_settings) => {
                    self.settings.collision = module_settings.clone();
                    self.settings.collision.normalize();
                }
                ParticleEmitterModuleSettings::Appearance(module_settings) => {
                    self.settings.appearance = module_settings.clone();
                    self.settings.appearance.normalize();
                }
                ParticleEmitterModuleSettings::TextureSheet(module_settings) => {
                    self.settings.texture_sheet = module_settings.clone();
                    self.settings.texture_sheet.normalize();
                }
                ParticleEmitterModuleSettings::Renderer(module_settings) => {
                    self.settings.renderer = module_settings.clone();
                    self.settings.renderer.normalize();
                }
                ParticleEmitterModuleSettings::Trails(module_settings) => {
                    self.settings.trails = module_settings.clone();
                    self.settings.trails.normalize();
                }
                ParticleEmitterModuleSettings::SubEmitters(module_settings) => {
                    self.settings.sub_emitters = module_settings.clone();
                    self.settings.sub_emitters.normalize();
                }
                ParticleEmitterModuleSettings::GpuSimulation(module_settings) => {
                    self.settings.gpu_simulation = module_settings.clone();
                    self.settings.gpu_simulation.normalize();
                }
            }
        }
        self.authored_module_stack = Some(module_stack);
    }
}
