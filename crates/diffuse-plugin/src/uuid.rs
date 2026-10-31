//! Foundation `UUID`: a v4 identifier that encodes as an uppercase hyphenated
//! string.
//!
//! Swift's `UUID` was used for request ids, transfer handles and mount
//! generations. `diffuse_capability::capability_contract::new_uuid` already
//! produces the same uppercase-hyphenated spelling for `None`-prefixed values,
//! but request ids need `Eq`/`Hash`/`Ord` to key maps, so this type wraps the
//! formatted string.

use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Uuid(String);

impl Uuid {
    /// `UUID()`: uppercase, hyphenated, 8-4-4-4-12.
    ///
    /// `diffuse_capability::capability_contract::new_uuid` formats the node as
    /// 10 hex digits instead of 12, so its strings are 34 characters and
    /// `Uuid::parse` (correctly) rejects them. This crate needs the real shape for
    /// request ids and transfer handles, so it formats the v4 layout itself.
    pub fn new() -> Uuid {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos() as u64)
            .unwrap_or(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        let time_low = (mixed & 0xFFFF_FFFF) as u32;
        let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
        let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
        let clock = ((counter & 0x3FFF) as u16) | 0x8000;
        // The node is 12 hex digits: eight from the mixed bits, four from the
        // counter so consecutive calls in one nanosecond still differ.
        let node_high = (mixed >> 8) as u32;
        let node_low = (counter & 0xFFFF) as u16;
        Uuid(format!(
            "{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node_high:08X}{node_low:04X}"
        ))
    }

    /// Parses the canonical hyphenated form; anything else is rejected, as
    /// `UUID(uuidString:)` rejected it.
    pub fn parse(value: &str) -> Option<Uuid> {
        let bytes = value.as_bytes();
        if bytes.len() != 36 {
            return None;
        }
        for (index, byte) in bytes.iter().enumerate() {
            match index {
                8 | 13 | 18 | 23 => {
                    if *byte != b'-' {
                        return None;
                    }
                }
                _ => {
                    if !byte.is_ascii_hexdigit() {
                        return None;
                    }
                }
            }
        }
        Some(Uuid(value.to_ascii_uppercase()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for Uuid {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Display for Uuid {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl serde::Serialize for Uuid {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> serde::Deserialize<'de> for Uuid {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
        let value = String::deserialize(deserializer)?;
        Uuid::parse(&value)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid UUID string: {value}")))
    }
}
