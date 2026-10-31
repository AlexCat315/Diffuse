//! Game save envelope — Swift `GameSave`.
//!
//! A save pairs a snapshot of the live scene with an optional game-defined state
//! payload (score, inventory, quest flags…) and free-form metadata. The whole
//! thing serializes to a single JSON document, so games get save/load without
//! having to make every runtime resource serializable.
//!
//! The embedded scene reflects the *current* runtime transforms and components.
//! Unlike an authored Scene or Prefab it also preserves active destruction
//! fragments and their remaining recycle budgets (both live in the
//! `SceneSerializer` game-save component codecs).
//!
//! Byte compatibility: `serialized` writes the document through
//! [`to_sorted_pretty`], the crate's reproduction of Swift's
//! `JSONSerialization.data(withJSONObject:options: [.prettyPrinted, .sortedKeys])`.
//! The nested `scene`/`state` documents are stored as their JSON text (Swift
//! stores `Data`), which keeps a loaded save round-tripping unchanged.

use std::collections::BTreeMap;

use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{Map, Value};
use thiserror::Error;

use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::{
    to_sorted_pretty, SceneSerializer, SceneSerializerError,
};

/// Swift `GameSaveError`: the only two failures `load` reports.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum GameSaveError {
    #[error("invalid game save format")]
    InvalidFormat,
    #[error("unsupported game save version: {0}")]
    UnsupportedVersion(i64),
}

/// Failures while capturing a live scene. Swift's `capture` rethrows whatever
/// `SceneSerializer`/`JSONEncoder` throws, so the two sources stay distinct here.
#[derive(Debug, Error)]
pub enum GameSaveCaptureError {
    #[error(transparent)]
    Scene(#[from] SceneSerializerError),
    #[error("failed to encode the game state: {0}")]
    State(#[from] serde_json::Error),
}

/// A savegame envelope: a scene snapshot, an optional game-state payload and
/// metadata.
///
/// Swift `GameSave` is a value type; `Clone` plus `BTreeMap` metadata reproduce
/// that, and the deterministic metadata order keeps output bytes stable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GameSave {
    /// Scene document in `SceneSerializer` format.
    pub scene: String,
    /// Optional game-state document (any JSON), or `None` when only the scene is
    /// saved.
    pub state: Option<String>,
    pub metadata: BTreeMap<String, String>,
}

impl GameSave {
    /// Swift `GameSave.currentVersion`.
    pub const CURRENT_VERSION: i64 = 2;

    pub fn new(scene: String, state: Option<String>, metadata: BTreeMap<String, String>) -> Self {
        GameSave {
            scene,
            state,
            metadata,
        }
    }

    // MARK: - Capture

    /// Captures the live scene only.
    pub fn capture(
        scene: &SceneRuntime,
        metadata: BTreeMap<String, String>,
    ) -> Result<GameSave, GameSaveCaptureError> {
        let document = SceneSerializer::serialize_game_state(scene.world())?;
        Ok(GameSave::new(document, None, metadata))
    }

    /// Captures the live scene plus an encodable game-state payload.
    pub fn capture_with_state<State: Serialize + ?Sized>(
        scene: &SceneRuntime,
        state: &State,
        metadata: BTreeMap<String, String>,
    ) -> Result<GameSave, GameSaveCaptureError> {
        let document = SceneSerializer::serialize_game_state(scene.world())?;
        let state = serde_json::to_string(state)?;
        Ok(GameSave::new(document, Some(state), metadata))
    }

    // MARK: - Serialize

    /// Encodes scene + state + metadata into one self-describing save document.
    ///
    /// Swift re-parses the embedded `Data` with `JSONSerialization`; a payload
    /// that is not valid JSON therefore fails the same way at this point.
    pub fn serialized(&self) -> Result<String, GameSaveError> {
        let scene_value: Value =
            serde_json::from_str(&self.scene).map_err(|_| GameSaveError::InvalidFormat)?;

        let mut root: Map<String, Value> = Map::new();
        root.insert(
            "version".to_string(),
            Value::from(GameSave::CURRENT_VERSION),
        );
        let metadata: Map<String, Value> = self
            .metadata
            .iter()
            .map(|(key, value)| (key.clone(), Value::String(value.clone())))
            .collect();
        root.insert("metadata".to_string(), Value::Object(metadata));
        root.insert("scene".to_string(), scene_value);

        if let Some(state) = &self.state {
            let state_value: Value =
                serde_json::from_str(state).map_err(|_| GameSaveError::InvalidFormat)?;
            root.insert("state".to_string(), state_value);
        }

        Ok(to_sorted_pretty(&Value::Object(root)))
    }

    /// Parses a save document produced by [`GameSave::serialized`].
    pub fn load(text: &str) -> Result<GameSave, GameSaveError> {
        let root: Value =
            serde_json::from_str(text).map_err(|_| GameSaveError::InvalidFormat)?;
        let Value::Object(root) = root else {
            return Err(GameSaveError::InvalidFormat);
        };

        // Swift: `(root["version"] as? NSNumber)?.intValue ?? 0`. JSON booleans
        // bridge to `NSNumber` there, so `true`/`false` read as 1/0; anything that
        // is not a number reads as 0.
        let version = root
            .get("version")
            .map(number_int_value)
            .unwrap_or(0);
        if version != GameSave::CURRENT_VERSION {
            return Err(GameSaveError::UnsupportedVersion(version));
        }

        let Some(scene_value) = root.get("scene") else {
            return Err(GameSaveError::InvalidFormat);
        };
        // Swift rebuilds the scene `Data` without `.prettyPrinted`; the text only
        // ever feeds `restore_scene`, so compactness here matches that behavior.
        let scene = serde_json::to_string(scene_value).map_err(|_| GameSaveError::InvalidFormat)?;

        // Swift: `(root["metadata"] as? [String: String]) ?? [:]`. The cast is
        // all-or-nothing: a single non-string value drops the whole mapping.
        let metadata = root
            .get("metadata")
            .and_then(metadata_string_map)
            .unwrap_or_default();

        // A present-but-null `state` stays `Some("null")`, exactly like Swift's
        // `if let stateObj = root["state"]`.
        let state = match root.get("state") {
            Some(state_value) => {
                Some(serde_json::to_string(state_value).map_err(|_| GameSaveError::InvalidFormat)?)
            }
            None => None,
        };

        Ok(GameSave::new(scene, state, metadata))
    }

    // MARK: - Restore

    /// Restores the saved scene into `scene` (entities are appended).
    pub fn restore_scene(&self, scene: &mut SceneRuntime) -> Result<(), SceneSerializerError> {
        SceneSerializer::deserialize_game_state(&self.scene, scene.world_mut())?;
        Ok(())
    }

    /// Decodes the game-state payload, or `None` if the save carried no state.
    pub fn decode_state<State: DeserializeOwned>(&self) -> Result<Option<State>, serde_json::Error> {
        match &self.state {
            None => Ok(None),
            Some(state) => serde_json::from_str(state).map(Some),
        }
    }
}

/// Swift `(value as? NSNumber)?.intValue`: truncates toward zero, saturates like
/// the `f64 as i64` cast the Foundation bridge performs.
fn number_int_value(value: &Value) -> i64 {
    match value {
        Value::Bool(true) => 1,
        Value::Bool(false) => 0,
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                integer
            } else if let Some(unsigned) = number.as_u64() {
                unsigned as i64
            } else {
                number.as_f64().map(|value| value as i64).unwrap_or(0)
            }
        }
        _ => 0,
    }
}

/// Swift `value as? [String: String]`: succeeds only when every entry is a string.
fn metadata_string_map(value: &Value) -> Option<BTreeMap<String, String>> {
    let Value::Object(entries) = value else {
        return None;
    };
    let mut metadata = BTreeMap::new();
    for (key, value) in entries {
        let Value::String(text) = value else {
            return None;
        };
        metadata.insert(key.clone(), text.clone());
    }
    Some(metadata)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    fn runtime() -> SceneRuntime {
        SceneRuntime::new(ComponentRegistry::new())
    }

    #[test]
    fn a_save_round_trips_scene_metadata_and_state() {
        let scene = runtime();
        let mut metadata = BTreeMap::new();
        metadata.insert("level".to_string(), "dock".to_string());
        let save = GameSave::capture(&scene, metadata).expect("capture");
        let state = save.serialized().expect("serialized");
        let loaded = GameSave::load(&state).expect("load");
        assert_eq!(loaded.metadata.get("level").map(String::as_str), Some("dock"));
        assert_eq!(loaded, save);
    }

    #[test]
    fn the_version_gate_rejects_other_documents() {
        let error = GameSave::load("{\"version\" : 3, \"scene\" : {}}").expect_err("version");
        assert_eq!(error, GameSaveError::UnsupportedVersion(3));
    }

    #[test]
    fn a_missing_scene_key_is_an_invalid_format() {
        let error = GameSave::load("{\"version\" : 2}").expect_err("scene");
        assert_eq!(error, GameSaveError::InvalidFormat);
    }

    #[test]
    fn metadata_is_dropped_when_a_single_value_is_not_a_string() {
        let save =
            GameSave::load("{\"version\" : 2, \"scene\" : {}, \"metadata\" : {\"a\" : \"x\", \"b\" : 1}}")
                .expect("load");
        assert!(save.metadata.is_empty());
    }

    #[test]
    fn a_null_state_is_kept_as_a_present_payload() {
        let save = GameSave::load("{\"version\" : 2, \"scene\" : {}, \"state\" : null}").expect("load");
        assert_eq!(save.state.as_deref(), Some("null"));
        let decoded: Option<Value> = save.decode_state().expect("decode");
        assert_eq!(decoded, Some(Value::Null));
    }

    #[test]
    fn a_boolean_version_reads_as_one() {
        let error = GameSave::load("{\"version\" : true, \"scene\" : {}}").expect_err("version");
        assert_eq!(error, GameSaveError::UnsupportedVersion(1));
    }
}
