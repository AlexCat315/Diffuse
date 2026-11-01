//! Stable attachment identity, distinct from process-local behavior handles.

use diffuse_scene::entity_id::RuntimeComponent;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ScriptBindingID {
    raw_value: String,
}

impl ScriptBindingID {
    pub fn new() -> Self {
        Self {
            raw_value: diffuse_kernel::codable::new_uuid(),
        }
    }

    pub fn from_uuid_string(value: &str) -> Option<Self> {
        if value.len() != 36
            || !value.bytes().enumerate().all(|(index, byte)| {
                if matches!(index, 8 | 13 | 18 | 23) {
                    byte == b'-'
                } else {
                    byte.is_ascii_hexdigit()
                }
            })
        {
            return None;
        }
        Some(Self {
            raw_value: value.to_ascii_uppercase(),
        })
    }

    pub fn raw_value(&self) -> &str {
        &self.raw_value
    }

    pub fn uuid_string(&self) -> String {
        self.raw_value.to_ascii_lowercase()
    }
}

impl Default for ScriptBindingID {
    fn default() -> Self {
        Self::new()
    }
}

impl Serialize for ScriptBindingID {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.uuid_string())
    }
}

impl<'de> Deserialize<'de> for ScriptBindingID {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        Self::from_uuid_string(&value).ok_or_else(|| {
            serde::de::Error::custom(format!("Invalid script binding UUID '{value}'."))
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ScriptHandle {
    pub raw_value: u64,
}

impl ScriptHandle {
    pub const fn new(raw_value: u64) -> Self {
        Self { raw_value }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScriptBinding {
    pub id: ScriptBindingID,
    pub script: ScriptHandle,
    pub identifier: Option<String>,
    pub is_enabled: bool,
    pub parameters_json: String,
}

impl ScriptBinding {
    pub fn new(
        script: ScriptHandle,
        id: ScriptBindingID,
        identifier: Option<String>,
        is_enabled: bool,
        parameters_json: impl Into<String>,
    ) -> Self {
        Self {
            id,
            script,
            identifier,
            is_enabled,
            parameters_json: parameters_json.into(),
        }
    }

    pub fn from_identifier(
        identifier: impl Into<String>,
        id: ScriptBindingID,
        is_enabled: bool,
        parameters_json: impl Into<String>,
    ) -> Self {
        Self::new(
            ScriptHandle::new(0),
            id,
            Some(identifier.into()),
            is_enabled,
            parameters_json,
        )
    }

    pub fn with_script(script: ScriptHandle) -> Self {
        Self::new(script, ScriptBindingID::new(), None, true, "{}")
    }

    pub fn with_identifier(identifier: impl Into<String>) -> Self {
        Self::from_identifier(identifier, ScriptBindingID::new(), true, "{}")
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScriptComponent {
    pub bindings: Vec<ScriptBinding>,
}

impl ScriptComponent {
    pub fn new(bindings: Vec<ScriptBinding>) -> Self {
        Self { bindings }
    }

    pub fn from_scripts(scripts: impl IntoIterator<Item = ScriptHandle>) -> Self {
        Self::new(
            scripts
                .into_iter()
                .map(ScriptBinding::with_script)
                .collect(),
        )
    }
}

impl RuntimeComponent for ScriptComponent {}
