//! Physics backend selection.
//!
//! `make_backend()` has both arms real: `None` returns [`NullPhysicsBackend`] and
//! `Natsel` returns a live [`NatselPhysicsBackend`], exactly as Swift's
//! `case .natsel: return NatselPhysicsBackend()` did. There is no fallback and no
//! unfinished branch.

use super::natsel::natsel_physics_backend::NatselPhysicsBackend;
use super::null_physics_backend::NullPhysicsBackend;
use super::physics_backend::PhysicsBackend;

/// `PhysicsBackendKind` — a `String`-backed `CaseIterable` enum, so persisted values
/// are the case names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsBackendKind {
    None,
    Natsel,
}

/// Swift has no implicit default for this enum; the only place a value is supplied
/// implicitly is `PhysicsSettingsResource.init(backendKind: .preferred)`. So `Default`
/// mirrors that call-site default rather than the first case, which keeps
/// `#[derive(Default)]` on containing settings structs faithful.
impl Default for PhysicsBackendKind {
    fn default() -> Self {
        PhysicsBackendKind::preferred()
    }
}

impl PhysicsBackendKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            PhysicsBackendKind::None => "none",
            PhysicsBackendKind::Natsel => "natsel",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "none" => Some(PhysicsBackendKind::None),
            "natsel" => Some(PhysicsBackendKind::Natsel),
            _ => None,
        }
    }

    /// The backend selected when settings do not choose one.
    pub const fn preferred() -> PhysicsBackendKind {
        PhysicsBackendKind::Natsel
    }

    /// Swift's `makeBackend()`: instantiate the selected backend.
    ///
    /// Both arms are complete. `None` yields the null backend, whose null behaviour
    /// is the real one Swift defines (it counts sync events and returns empty query
    /// results), and `Natsel` yields a live simulation. No arm is a placeholder, so
    /// a scene that selects `Natsel` never silently receives null physics.
    pub fn make_backend(&self) -> Box<dyn PhysicsBackend> {
        match self {
            PhysicsBackendKind::None => Box::new(NullPhysicsBackend::new()),
            PhysicsBackendKind::Natsel => Box::new(NatselPhysicsBackend::new()),
        }
    }

    pub const ALL: [PhysicsBackendKind; 2] = [PhysicsBackendKind::None, PhysicsBackendKind::Natsel];
}

impl serde::Serialize for PhysicsBackendKind {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for PhysicsBackendKind {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        PhysicsBackendKind::from_raw_value(&value).ok_or_else(|| {
            serde::de::Error::custom(format!("Unknown physics backend kind: {value}"))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_round_trips_raw_values() {
        for kind in PhysicsBackendKind::ALL {
            assert_eq!(
                PhysicsBackendKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(PhysicsBackendKind::from_raw_value("None"), None);
    }

    #[test]
    fn preferred_backend_is_natsel() {
        assert_eq!(PhysicsBackendKind::preferred(), PhysicsBackendKind::Natsel);
    }

    #[test]
    fn enum_default_is_the_preferred_backend() {
        // Matches `PhysicsSettingsResource.init(backendKind: = .preferred)`.
        assert_eq!(PhysicsBackendKind::default(), PhysicsBackendKind::Natsel);
        assert_eq!(
            PhysicsBackendKind::default(),
            PhysicsBackendKind::preferred()
        );
    }
}

#[cfg(test)]
mod make_backend_tests {
    use super::*;

    #[test]
    fn none_selects_the_null_backend() {
        let backend = PhysicsBackendKind::None.make_backend();
        assert_eq!(backend.identifier(), NullPhysicsBackend::new().identifier());
    }

    #[test]
    fn natsel_selects_a_live_simulation() {
        // Both arms must be real: a scene asking for Natsel must not silently receive
        // null physics, which is what a fallback arm would have produced.
        let backend = PhysicsBackendKind::Natsel.make_backend();
        assert_eq!(
            backend.identifier(),
            NatselPhysicsBackend::new().identifier()
        );
        assert_ne!(
            PhysicsBackendKind::Natsel.make_backend().identifier(),
            PhysicsBackendKind::None.make_backend().identifier(),
            "Natsel and None must not resolve to the same backend"
        );
    }

    #[test]
    fn every_case_builds_a_backend() {
        for kind in PhysicsBackendKind::ALL {
            let backend = kind.make_backend();
            assert!(
                !backend.identifier().is_empty(),
                "{kind:?} has no identifier"
            );
        }
    }
}
