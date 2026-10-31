//! Swift's `Date` encoding: seconds since 2001-01-01 in UTC.

/// Swift's date reference epoch in Unix seconds.
pub const SWIFT_DATE_REFERENCE_UNIX_SECONDS: i64 = 978_307_200;

/// A timestamp carried in Swift's `Date` encoding.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    #[inline]
    pub fn now() -> Self {
        let unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs_f64())
            .unwrap_or(0.0);
        SwiftDate(unix - SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64)
    }
}

impl serde::Serialize for SwiftDate {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_f64(self.0)
    }
}

impl<'de> serde::Deserialize<'de> for SwiftDate {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<SwiftDate, D::Error> {
        f64::deserialize(deserializer).map(SwiftDate)
    }
}
