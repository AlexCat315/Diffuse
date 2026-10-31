//! `EventSymbolicView` — the LLM-safe, redacted and compacted view of a stream.
//!
//! Exclusion rules (design §15):
//! 1. Kinds whose `redactInPrompt == true` are dropped entirely.
//! 2. `runtime.tick` and `runtime.metric.sampled` are dropped.
//! 3. Handle payloads yield `{ "payload": "<handle:store/key>" }`.
//! 4. Deeply nested objects are compacted to their top-level keys only.

use crate::event_envelope::{EventEnvelope, EventPayloadRecord, EventPayloadRef, EventProvenance};
use crate::event_kind_registry::EventKindId;
use crate::publisher::ObservationBus;

/// A single LLM-safe event.
#[derive(Clone, Debug, PartialEq)]
pub struct SymbolicEvent {
    pub kind: EventKindId,
    pub stream_id: String,
    pub seq: u64,
    pub causation_id: Option<String>,
    pub provenance: EventProvenance,
    /// Key/value summary after redaction.
    pub summary: std::collections::BTreeMap<String, String>,
}

impl SymbolicEvent {
    #[inline]
    pub fn new(
        kind: EventKindId,
        stream_id: String,
        seq: u64,
        causation_id: Option<String>,
        provenance: EventProvenance,
        summary: std::collections::BTreeMap<String, String>,
    ) -> Self {
        SymbolicEvent {
            kind,
            stream_id,
            seq,
            causation_id,
            provenance,
            summary,
        }
    }
}

/// Describes which part of the bus ring the view covers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventSymbolicViewWindow {
    pub stream_id: String,
    pub from_seq: u64,
    pub to_seq: u64,
    pub max_count: usize,
}

impl EventSymbolicViewWindow {
    #[inline]
    pub fn new(stream_id: String, from_seq: u64, to_seq: u64, max_count: usize) -> Self {
        EventSymbolicViewWindow {
            stream_id,
            from_seq,
            to_seq,
            max_count,
        }
    }
}

/// The LLM-facing view of a bus window: redacted, filtered and compacted.
#[derive(Clone, Debug, PartialEq)]
pub struct EventSymbolicView {
    pub window: EventSymbolicViewWindow,
    pub events: Vec<SymbolicEvent>,
}

impl EventSymbolicView {
    #[inline]
    pub fn new(window: EventSymbolicViewWindow, events: Vec<SymbolicEvent>) -> Self {
        EventSymbolicView { window, events }
    }

    /// Renders the view as a compact multi-line string for LLM injection.
    pub fn prompt_text(&self) -> String {
        if self.events.is_empty() {
            return "(no recent observable events)".to_string();
        }
        let mut lines = vec![format!(
            "Recent events (stream: {}, seq {}–{}):",
            self.window.stream_id, self.window.from_seq, self.window.to_seq
        )];
        for event in &self.events {
            let mut parts = vec![format!("  [{}] {}", event.seq, event.kind.raw_value())];
            if let Some(causation_id) = &event.causation_id {
                parts.push(format!("cause={causation_id}"));
            }
            if event.provenance != EventProvenance::Authored {
                parts.push(format!("prov={}", provenance_raw_value(event.provenance)));
            }
            if !event.summary.is_empty() {
                // `BTreeMap` iterates in key order, matching Swift's explicit sort.
                let key_values: Vec<String> = event
                    .summary
                    .iter()
                    .map(|(key, value)| format!("{key}={value}"))
                    .collect();
                parts.push(key_values.join(" "));
            }
            lines.push(parts.join(" "));
        }
        lines.join("\n")
    }
}

fn provenance_raw_value(provenance: EventProvenance) -> &'static str {
    match provenance {
        EventProvenance::Authored => "authored",
        EventProvenance::Evaluated => "evaluated",
        EventProvenance::Runtime => "runtime",
        EventProvenance::Baked => "baked",
        EventProvenance::Inferred => "inferred",
    }
}

const EXCLUDED_FROM_PROMPT: [EventKindId; 2] =
    [EventKindId::RuntimeTick, EventKindId::RuntimeMetricSampled];

impl ObservationBus {
    /// Returns a symbolic (LLM-safe) view of recent events in `stream_id`.
    pub fn symbolic_view(
        &self,
        stream_id: &str,
        from_seq: u64,
        max_count: usize,
    ) -> EventSymbolicView {
        let raw: Vec<EventEnvelope> = self
            .events(stream_id)
            .into_iter()
            .filter(|envelope| envelope.seq >= from_seq)
            .collect();
        let filtered: Vec<EventEnvelope> = raw
            .into_iter()
            .filter(|envelope| {
                !EXCLUDED_FROM_PROMPT.contains(&envelope.kind)
                    && !self.registry.spec(envelope.kind).redact_in_prompt
            })
            .collect();

        let capped: Vec<EventEnvelope> = if filtered.len() > max_count {
            filtered[filtered.len() - max_count..].to_vec()
        } else {
            filtered
        };
        let from_seq_actual = capped
            .first()
            .map(|envelope| envelope.seq)
            .unwrap_or(from_seq);
        let to_seq_actual = capped
            .last()
            .map(|envelope| envelope.seq)
            .unwrap_or(from_seq);
        let symbolic: Vec<SymbolicEvent> = capped
            .iter()
            .map(|envelope| self.symbolicate(envelope))
            .collect();
        EventSymbolicView::new(
            EventSymbolicViewWindow::new(
                stream_id.to_string(),
                from_seq_actual,
                to_seq_actual,
                max_count,
            ),
            symbolic,
        )
    }

    fn symbolicate(&self, envelope: &EventEnvelope) -> SymbolicEvent {
        let summary = match &envelope.payload_ref {
            EventPayloadRef::Inline { record } => compact_summary(record),
            EventPayloadRef::Handle(handle) => {
                let mut map = std::collections::BTreeMap::new();
                map.insert(
                    "payload".to_string(),
                    format!("<handle:{}/{}>", handle.store, handle.key),
                );
                map
            }
        };
        SymbolicEvent::new(
            envelope.kind,
            envelope.stream_id.clone(),
            envelope.seq,
            envelope.causation_id.clone(),
            envelope.provenance,
            summary,
        )
    }
}

fn compact_summary(record: &EventPayloadRecord) -> std::collections::BTreeMap<String, String> {
    use crate::event_envelope::EventValue;

    let mut out = std::collections::BTreeMap::new();
    for (key, value) in record {
        let text = match value {
            EventValue::String(text) => {
                // Swift counts characters, not bytes (MIGRATION.md §5.2).
                let characters: Vec<char> = text.chars().collect();
                if characters.len() > 120 {
                    characters[..120].iter().collect::<String>() + "…"
                } else {
                    text.clone()
                }
            }
            EventValue::Integer(value) => value.to_string(),
            // Swift's `%.4g`.
            EventValue::Number(value) => format_general(*value, 4),
            EventValue::Boolean(value) => value.to_string(),
            EventValue::Array(_) => "<array>".to_string(),
            EventValue::Object(_) => "<object>".to_string(),
            EventValue::Null => "null".to_string(),
        };
        out.insert(key.clone(), text);
    }
    out
}

/// C's `%.4g`, which Swift's `String(format: "%.4g", n)` uses.
pub fn format_general(value: f64, precision: usize) -> String {
    if value == 0.0 {
        return "0".to_string();
    }
    if !value.is_finite() {
        return if value.is_nan() {
            "nan".to_string()
        } else if value.is_sign_negative() {
            "-inf".to_string()
        } else {
            "inf".to_string()
        };
    }
    let exponent = value.abs().log10().floor() as i32;
    if exponent < -4 || exponent >= precision as i32 {
        let formatted = format!("{:.*e}", precision.saturating_sub(1), value);
        return normalize_exponent(&formatted);
    }
    let decimals = (precision as i32 - exponent - 1).max(0) as usize;
    let formatted = format!("{value:.decimals$}");
    trim_trailing_zeros(&formatted)
}

fn normalize_exponent(value: &str) -> String {
    // Rust prints `1.0000e5`; C prints `1.000e+05`.
    match value.split_once('e') {
        Some((mantissa, exponent)) => {
            let mantissa = trim_trailing_zeros(mantissa);
            let exponent_value: i32 = exponent.parse().unwrap_or(0);
            format!(
                "{mantissa}e{}{:02}",
                if exponent_value < 0 { '-' } else { '+' },
                exponent_value.abs()
            )
        }
        None => value.to_string(),
    }
}

fn trim_trailing_zeros(value: &str) -> String {
    if !value.contains('.') {
        return value.to_string();
    }
    let trimmed = value.trim_end_matches('0').trim_end_matches('.');
    if trimmed.is_empty() {
        "0".to_string()
    } else {
        trimmed.to_string()
    }
}
