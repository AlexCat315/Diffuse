//! `EventEnvelope` and the payload vocabulary.
//!
//! The JSON shape is Swift `Codable`'s (MIGRATION.md §5.4): property names as-is,
//! `EventValue` encoded as a bare JSON value, and `EventPayloadRef` encoded as
//! `{kind, record|handle}`.

use serde::de::{self, Deserializer, MapAccess, Visitor};
use serde::ser::{SerializeMap, Serializer};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;

/// `EventPayloadRecord = [String: EventValue]`. Swift dictionaries are unordered;
/// call sites sort before use, so a `BTreeMap` keeps output deterministic.
pub type EventPayloadRecord = BTreeMap<String, EventValue>;

#[derive(Clone, Debug, PartialEq)]
pub enum EventValue {
    String(String),
    Integer(i64),
    Number(f64),
    Boolean(bool),
    Array(Vec<EventValue>),
    Object(EventPayloadRecord),
    Null,
}

impl EventValue {
    /// Swift's `String(describing:)` for the cases used by `description`.
    pub fn description(&self) -> String {
        match self {
            EventValue::String(value) => value.clone(),
            EventValue::Integer(value) => value.to_string(),
            EventValue::Number(value) => format_double(*value),
            EventValue::Boolean(value) => value.to_string(),
            EventValue::Array(values) => {
                let joined: Vec<String> = values.iter().map(EventValue::description).collect();
                format!("[{}]", joined.join(","))
            }
            EventValue::Object(values) => {
                let mut entries: Vec<String> = values
                    .iter()
                    .map(|(key, value)| format!("{key}={}", value.description()))
                    .collect();
                entries.sort();
                format!("{{{}}}", entries.join(","))
            }
            EventValue::Null => "null".to_string(),
        }
    }
}

/// Swift prints a `Double` with a fractional part (`String(1.0) == "1.0"`).
pub(crate) fn format_double(value: f64) -> String {
    if value.is_finite() && value.fract() == 0.0 && value.abs() < 1e16 {
        format!("{value:.1}")
    } else {
        format!("{value}")
    }
}

impl Serialize for EventValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            EventValue::String(value) => serializer.serialize_str(value),
            EventValue::Integer(value) => serializer.serialize_i64(*value),
            EventValue::Number(value) => serializer.serialize_f64(*value),
            EventValue::Boolean(value) => serializer.serialize_bool(*value),
            EventValue::Array(values) => values.serialize(serializer),
            EventValue::Object(values) => values.serialize(serializer),
            EventValue::Null => serializer.serialize_unit(),
        }
    }
}

struct EventValueVisitor;

impl<'de> Visitor<'de> for EventValueVisitor {
    type Value = EventValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("an EventValue payload")
    }

    fn visit_unit<E: de::Error>(self) -> Result<EventValue, E> {
        Ok(EventValue::Null)
    }

    fn visit_none<E: de::Error>(self) -> Result<EventValue, E> {
        Ok(EventValue::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<EventValue, D::Error> {
        EventValue::deserialize(deserializer)
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<EventValue, E> {
        Ok(EventValue::Boolean(value))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<EventValue, E> {
        Ok(EventValue::Integer(value))
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<EventValue, E> {
        Ok(EventValue::Integer(value as i64))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<EventValue, E> {
        Ok(EventValue::Number(value))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<EventValue, E> {
        Ok(EventValue::String(value.to_string()))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<EventValue, E> {
        Ok(EventValue::String(value))
    }

    fn visit_seq<A: de::SeqAccess<'de>>(self, mut seq: A) -> Result<EventValue, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = seq.next_element::<EventValue>()? {
            values.push(value);
        }
        Ok(EventValue::Array(values))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<EventValue, A::Error> {
        let mut values = EventPayloadRecord::new();
        while let Some((key, value)) = map.next_entry::<String, EventValue>()? {
            values.insert(key, value);
        }
        Ok(EventValue::Object(values))
    }
}

impl<'de> Deserialize<'de> for EventValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<EventValue, D::Error> {
        deserializer.deserialize_any(EventValueVisitor)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventPayloadHandle {
    pub store: String,
    pub key: String,
    pub content_hash: String,
}

impl EventPayloadHandle {
    #[inline]
    pub fn new(
        store: impl Into<String>,
        key: impl Into<String>,
        content_hash: impl Into<String>,
    ) -> Self {
        EventPayloadHandle {
            store: store.into(),
            key: key.into(),
            content_hash: content_hash.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum EventPayloadRef {
    Inline { record: EventPayloadRecord },
    Handle(EventPayloadHandle),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PayloadRefKind {
    Inline,
    Handle,
}

impl Serialize for EventPayloadRef {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(None)?;
        match self {
            EventPayloadRef::Inline { record } => {
                map.serialize_entry("kind", "inline")?;
                map.serialize_entry("record", record)?;
            }
            EventPayloadRef::Handle(handle) => {
                map.serialize_entry("kind", "handle")?;
                map.serialize_entry("handle", handle)?;
            }
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for EventPayloadRef {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<EventPayloadRef, D::Error> {
        struct PayloadRefVisitor;

        impl<'de> Visitor<'de> for PayloadRefVisitor {
            type Value = EventPayloadRef;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an EventPayloadRef")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<EventPayloadRef, A::Error> {
                let mut kind: Option<PayloadRefKind> = None;
                let mut record: Option<EventPayloadRecord> = None;
                let mut handle: Option<EventPayloadHandle> = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "kind" => {
                            let value: String = map.next_value()?;
                            kind = Some(match value.as_str() {
                                "inline" => PayloadRefKind::Inline,
                                "handle" => PayloadRefKind::Handle,
                                other => {
                                    return Err(de::Error::unknown_variant(
                                        other,
                                        &["inline", "handle"],
                                    ));
                                }
                            });
                        }
                        "record" => record = Some(map.next_value()?),
                        "handle" => handle = Some(map.next_value()?),
                        _ => {
                            let _: de::IgnoredAny = map.next_value()?;
                        }
                    }
                }
                match kind {
                    Some(PayloadRefKind::Inline) => Ok(EventPayloadRef::Inline {
                        record: record.ok_or_else(|| de::Error::missing_field("record"))?,
                    }),
                    Some(PayloadRefKind::Handle) => Ok(EventPayloadRef::Handle(
                        handle.ok_or_else(|| de::Error::missing_field("handle"))?,
                    )),
                    None => Err(de::Error::missing_field("kind")),
                }
            }
        }

        deserializer.deserialize_map(PayloadRefVisitor)
    }
}

impl EventPayloadRef {
    #[inline]
    pub fn inline(record: EventPayloadRecord) -> Self {
        EventPayloadRef::Inline { record }
    }

    #[inline]
    pub fn inline_record(&self) -> Option<&EventPayloadRecord> {
        match self {
            EventPayloadRef::Inline { record } => Some(record),
            EventPayloadRef::Handle(_) => None,
        }
    }

    /// Swift's `coalesceKey(for:)`, kept here so subscriptions can group events.
    pub fn coalesce_key(&self, fields: &[String]) -> Option<String> {
        let record = self.inline_record()?;
        let mut parts = Vec::with_capacity(fields.len());
        for field in fields {
            let value = record.get(field)?;
            parts.push(format!("{field}={}", value.description()));
        }
        if parts.len() != fields.len() {
            return None;
        }
        Some(parts.join("|"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventOriginProcessKind {
    Editor,
    Runtime,
    #[serde(rename = "render_farm")]
    RenderFarm,
    Tool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventOrigin {
    pub process: EventOriginProcessKind,
    pub host: String,
    pub user: Option<String>,
    pub agent: Option<String>,
}

impl EventOrigin {
    #[inline]
    pub fn new(
        process: EventOriginProcessKind,
        host: impl Into<String>,
        user: Option<String>,
        agent: Option<String>,
    ) -> Self {
        EventOrigin {
            process,
            host: host.into(),
            user,
            agent,
        }
    }

    /// Swift's `EventOrigin.tool(user:agent:)` uses the machine host name.
    pub fn tool(user: Option<String>, agent: Option<String>) -> Self {
        EventOrigin::new(EventOriginProcessKind::Tool, host_name(), user, agent)
    }
}

/// `ProcessInfo.processInfo.hostName`.
pub fn host_name() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            std::fs::read_to_string("/proc/sys/kernel/hostname")
                .ok()
                .map(|value| value.trim().to_string())
        })
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .unwrap_or_else(|| "localhost".to_string())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventProvenance {
    Authored,
    Evaluated,
    Runtime,
    Baked,
    Inferred,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EventEnvelope {
    #[serde(rename = "eventID")]
    pub event_id: String,
    pub kind: crate::event_kind_registry::EventKindId,
    #[serde(rename = "streamID")]
    pub stream_id: String,
    pub seq: u64,
    #[serde(rename = "causalSeq")]
    pub causal_seq: Option<u64>,
    #[serde(rename = "monotonicTimestampNS")]
    pub monotonic_timestamp_ns: u64,
    #[serde(rename = "wallTimestampUTCMS")]
    pub wall_timestamp_utc_ms: i64,
    pub origin: EventOrigin,
    #[serde(rename = "causationID")]
    pub causation_id: Option<String>,
    #[serde(rename = "correlationID")]
    pub correlation_id: Option<String>,
    pub provenance: EventProvenance,
    #[serde(rename = "payloadRef")]
    pub payload_ref: EventPayloadRef,
    pub schema_version: u32,
    pub replay: bool,
}

impl EventEnvelope {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        event_id: impl Into<String>,
        kind: crate::event_kind_registry::EventKindId,
        stream_id: impl Into<String>,
        seq: u64,
        causal_seq: Option<u64>,
        monotonic_timestamp_ns: u64,
        wall_timestamp_utc_ms: i64,
        origin: EventOrigin,
        causation_id: Option<String>,
        correlation_id: Option<String>,
        provenance: EventProvenance,
        payload_ref: EventPayloadRef,
        schema_version: u32,
        replay: bool,
    ) -> Self {
        EventEnvelope {
            event_id: event_id.into(),
            kind,
            stream_id: stream_id.into(),
            seq,
            causal_seq,
            monotonic_timestamp_ns,
            wall_timestamp_utc_ms,
            origin,
            causation_id,
            correlation_id,
            provenance,
            payload_ref,
            schema_version,
            replay,
        }
    }
}

/// Note the Swift type declares `schemaVersion = 1` and `replay = false` defaults;
/// `new` above takes them explicitly so callers keep those values.
pub const DEFAULT_SCHEMA_VERSION: u32 = 1;
