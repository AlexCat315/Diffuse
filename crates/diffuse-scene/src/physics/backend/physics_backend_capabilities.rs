//! Optional simulation features a backend implements beyond rigid bodies,
//! colliders, basic joints and queries.

/// Swift's `OptionSet` over `UInt32`; the raw bit layout is preserved.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct PhysicsBackendCapabilities {
    pub raw_value: u32,
}

impl PhysicsBackendCapabilities {
    pub const CHARACTERS: PhysicsBackendCapabilities =
        PhysicsBackendCapabilities { raw_value: 1 << 0 };
    pub const VEHICLES: PhysicsBackendCapabilities =
        PhysicsBackendCapabilities { raw_value: 1 << 1 };
    pub const SOFT_BODIES: PhysicsBackendCapabilities =
        PhysicsBackendCapabilities { raw_value: 1 << 2 };
    pub const CONE_JOINTS: PhysicsBackendCapabilities =
        PhysicsBackendCapabilities { raw_value: 1 << 3 };
    pub const SIX_DOF_JOINTS: PhysicsBackendCapabilities =
        PhysicsBackendCapabilities { raw_value: 1 << 4 };
    pub const CYLINDER_COLLIDERS: PhysicsBackendCapabilities =
        PhysicsBackendCapabilities { raw_value: 1 << 5 };

    #[inline]
    pub const fn new(raw_value: u32) -> Self {
        PhysicsBackendCapabilities { raw_value }
    }

    #[inline]
    pub const fn contains(&self, other: PhysicsBackendCapabilities) -> bool {
        (self.raw_value & other.raw_value) == other.raw_value
    }

    #[inline]
    pub fn insert(&mut self, other: PhysicsBackendCapabilities) {
        self.raw_value |= other.raw_value;
    }

    #[inline]
    pub fn remove(&mut self, other: PhysicsBackendCapabilities) {
        self.raw_value &= !other.raw_value;
    }

    #[inline]
    pub const fn is_empty(&self) -> bool {
        self.raw_value == 0
    }

    /// `static let all` — every optional feature.
    pub const fn all() -> PhysicsBackendCapabilities {
        PhysicsBackendCapabilities {
            raw_value: PhysicsBackendCapabilities::CHARACTERS.raw_value
                | PhysicsBackendCapabilities::VEHICLES.raw_value
                | PhysicsBackendCapabilities::SOFT_BODIES.raw_value
                | PhysicsBackendCapabilities::CONE_JOINTS.raw_value
                | PhysicsBackendCapabilities::SIX_DOF_JOINTS.raw_value
                | PhysicsBackendCapabilities::CYLINDER_COLLIDERS.raw_value,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_contains_every_feature() {
        let all = PhysicsBackendCapabilities::all();
        for feature in [
            PhysicsBackendCapabilities::CHARACTERS,
            PhysicsBackendCapabilities::VEHICLES,
            PhysicsBackendCapabilities::SOFT_BODIES,
            PhysicsBackendCapabilities::CONE_JOINTS,
            PhysicsBackendCapabilities::SIX_DOF_JOINTS,
            PhysicsBackendCapabilities::CYLINDER_COLLIDERS,
        ] {
            assert!(all.contains(feature));
        }
        assert_eq!(all.raw_value, 0b11_1111);
    }

    #[test]
    fn empty_set_contains_nothing_but_is_contained_by_all() {
        let empty = PhysicsBackendCapabilities::new(0);
        assert!(empty.is_empty());
        assert!(!empty.contains(PhysicsBackendCapabilities::CHARACTERS));
        assert!(PhysicsBackendCapabilities::all().contains(empty));
    }

    #[test]
    fn insert_and_remove_toggle_bits() {
        let mut caps = PhysicsBackendCapabilities::new(0);
        caps.insert(PhysicsBackendCapabilities::VEHICLES);
        assert!(caps.contains(PhysicsBackendCapabilities::VEHICLES));
        caps.remove(PhysicsBackendCapabilities::VEHICLES);
        assert!(!caps.contains(PhysicsBackendCapabilities::VEHICLES));
    }

    #[test]
    fn contains_requires_every_bit_of_the_argument() {
        let mut caps = PhysicsBackendCapabilities::new(0);
        caps.insert(PhysicsBackendCapabilities::CHARACTERS);
        assert!(!caps.contains(PhysicsBackendCapabilities::all()));
        assert!(PhysicsBackendCapabilities::all().contains(caps));
    }
}
