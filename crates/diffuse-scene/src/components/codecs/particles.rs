//! `Codecs/Particles.swift` — the persisted shape of a particle emitter.
//!
//! Only the authored configuration is stored: the settings tree and the module
//! stack. The live particle pool and RNG state are transient runtime state and are
//! never persisted, so decoding always builds a fresh emitter through
//! [`ParticleEmitter::new`] (which re-seeds from `settings.emission.seed` and
//! normalizes) and then replays the stored modules via
//! [`ParticleEmitter::apply`].

use std::collections::BTreeMap;

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{decode_json_value, encode_json_value, object};
use crate::components::core::value::ComponentValue;
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_modules::ParticleModuleStack;

impl BuiltinComponentCodecs {
    /// Swift `serializeParticleEmitter` — configuration only, no particle pool.
    pub fn serialize_particle_emitter(
        emitter: &ParticleEmitter,
    ) -> BTreeMap<String, ComponentValue> {
        let mut record = object([]);
        if let Some(settings) = encode_json_value(&emitter.settings) {
            record.insert("settings".to_string(), settings);
        }
        if let Some(module_stack) = encode_json_value(&emitter.module_stack()) {
            record.insert("moduleStack".to_string(), module_stack);
        }
        record
    }

    /// Swift `deserializeParticleEmitter` — undecodable settings fall back to
    /// `ParticleEmitterSettings()`, an undecodable module stack is ignored.
    pub fn deserialize_particle_emitter(
        record: &BTreeMap<String, ComponentValue>,
    ) -> ParticleEmitter {
        let settings = decode_json_value::<ParticleEmitterSettings>(record.get("settings"))
            .unwrap_or_default();
        let mut emitter = ParticleEmitter::new(settings);
        if let Some(module_stack) =
            decode_json_value::<ParticleModuleStack>(record.get("moduleStack"))
        {
            emitter.apply(module_stack);
        }
        emitter
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::component_json_helpers::json_to_dict;

    #[test]
    fn an_empty_record_decodes_the_default_emitter() {
        let emitter = BuiltinComponentCodecs::deserialize_particle_emitter(&BTreeMap::new());
        assert_eq!(emitter.settings, ParticleEmitterSettings::default());
        assert!(emitter.particles().is_empty());
    }

    #[test]
    fn settings_and_module_stack_are_both_persisted() {
        let emitter = ParticleEmitter::new(ParticleEmitterSettings::default());
        let record = BuiltinComponentCodecs::serialize_particle_emitter(&emitter);
        assert!(json_to_dict(record.get("settings")).is_some());
        assert!(json_to_dict(record.get("moduleStack")).is_some());

        let decoded = BuiltinComponentCodecs::deserialize_particle_emitter(&record);
        assert_eq!(decoded.settings, emitter.settings);
    }

    #[test]
    fn a_malformed_module_stack_is_ignored() {
        let mut record = BTreeMap::new();
        record.insert(
            "moduleStack".to_string(),
            ComponentValue::Array(Vec::new()),
        );
        let emitter = BuiltinComponentCodecs::deserialize_particle_emitter(&record);
        assert_eq!(emitter.settings, ParticleEmitterSettings::default());
    }
}
