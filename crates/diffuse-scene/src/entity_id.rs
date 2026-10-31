//! Entity identity and the component marker trait.

use std::fmt;

/// `EntityID` — a slot index paired with a reuse generation. Swift declares the
/// two fields `let`, so both are immutable after construction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EntityID {
    pub index: u32,
    pub generation: u32,
}

impl EntityID {
    #[inline]
    pub const fn new(index: u32, generation: u32) -> Self {
        EntityID { index, generation }
    }

    /// `init(rawValue:)` — `truncatingIfNeeded` keeps the low 32 bits as the
    /// index and the next 32 bits as the generation.
    #[inline]
    pub const fn from_raw_value(raw_value: u64) -> Self {
        EntityID {
            index: raw_value as u32,
            generation: (raw_value >> 32) as u32,
        }
    }

    #[inline]
    pub const fn raw_value(&self) -> u64 {
        ((self.generation as u64) << 32) | self.index as u64
    }
}

impl fmt::Display for EntityID {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "EntityID(index: {}, generation: {})",
            self.index, self.generation
        )
    }
}

/// Swift's `public protocol RuntimeComponent: Sendable {}` — a marker for types a
/// [`crate::runtime_world::RuntimeWorld`] can store.
///
/// Swift removes `Sendable` on the Rust side (MIGRATION.md §5.2), but the bound is
/// kept so component stores are safe to move across the job system. `'static` is
/// the Rust stand-in for `ObjectIdentifier(type)`, which the registry uses as the
/// component's identity token.
pub trait RuntimeComponent: Clone + PartialEq + Send + Sync + 'static {}
