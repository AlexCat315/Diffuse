//! Physics error and simulation-mode vocabulary.

/// `PhysicsSimulationMode` — a `String`-backed enum; persisted values are the case
/// names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsSimulationMode {
    Off,
    Preview,
    Play,
    Bake,
}

impl PhysicsSimulationMode {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            PhysicsSimulationMode::Off => "off",
            PhysicsSimulationMode::Preview => "preview",
            PhysicsSimulationMode::Play => "play",
            PhysicsSimulationMode::Bake => "bake",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "off" => Some(PhysicsSimulationMode::Off),
            "preview" => Some(PhysicsSimulationMode::Preview),
            "play" => Some(PhysicsSimulationMode::Play),
            "bake" => Some(PhysicsSimulationMode::Bake),
            _ => None,
        }
    }

    pub const ALL: [PhysicsSimulationMode; 4] = [
        PhysicsSimulationMode::Off,
        PhysicsSimulationMode::Preview,
        PhysicsSimulationMode::Play,
        PhysicsSimulationMode::Bake,
    ];
}

impl serde::Serialize for PhysicsSimulationMode {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for PhysicsSimulationMode {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        PhysicsSimulationMode::from_raw_value(&value).ok_or_else(|| {
            serde::de::Error::custom(format!("Unknown physics simulation mode: {value}"))
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsBackendErrorCode {
    AbiMismatch,
    InvalidArgument,
    InvalidShape,
    BodyCreationFailed,
    UpdateFailed,
    Unknown,
}

impl PhysicsBackendErrorCode {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            PhysicsBackendErrorCode::AbiMismatch => "abiMismatch",
            PhysicsBackendErrorCode::InvalidArgument => "invalidArgument",
            PhysicsBackendErrorCode::InvalidShape => "invalidShape",
            PhysicsBackendErrorCode::BodyCreationFailed => "bodyCreationFailed",
            PhysicsBackendErrorCode::UpdateFailed => "updateFailed",
            PhysicsBackendErrorCode::Unknown => "unknown",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "abiMismatch" => Some(PhysicsBackendErrorCode::AbiMismatch),
            "invalidArgument" => Some(PhysicsBackendErrorCode::InvalidArgument),
            "invalidShape" => Some(PhysicsBackendErrorCode::InvalidShape),
            "bodyCreationFailed" => Some(PhysicsBackendErrorCode::BodyCreationFailed),
            "updateFailed" => Some(PhysicsBackendErrorCode::UpdateFailed),
            "unknown" => Some(PhysicsBackendErrorCode::Unknown),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{code:?}: {message}")]
pub struct PhysicsBackendError {
    pub code: PhysicsBackendErrorCode,
    pub message: String,
}

impl PhysicsBackendError {
    pub fn new(code: PhysicsBackendErrorCode, message: impl Into<String>) -> Self {
        PhysicsBackendError {
            code,
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simulation_mode_round_trips() {
        for mode in PhysicsSimulationMode::ALL {
            assert_eq!(
                PhysicsSimulationMode::from_raw_value(mode.raw_value()),
                Some(mode)
            );
        }
        assert_eq!(PhysicsSimulationMode::from_raw_value("Off"), None);
    }

    #[test]
    fn backend_error_code_round_trips() {
        assert_eq!(
            PhysicsBackendErrorCode::from_raw_value("bodyCreationFailed"),
            Some(PhysicsBackendErrorCode::BodyCreationFailed)
        );
        assert_eq!(
            PhysicsBackendErrorCode::AbiMismatch.raw_value(),
            "abiMismatch"
        );
    }
}
