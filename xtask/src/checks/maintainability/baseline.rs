//! The frozen debt list. Keys are `path::QualifiedType` identities; the values
//! hold the per-metric allowance that must not grow. `reason` strings are
//! documentation and are ignored when loading.

use crate::support::terminal::ToolError;
use serde_json::Value;
use std::collections::BTreeMap;

/// The baseline ships beside this module: the Swift package declared it as a
/// `.copy` resource, and Cargo has no resource bundles, so `include_str!` keeps
/// the same bytes inside the binary.
const BASELINE_JSON: &str = include_str!("swift-maintainability-baseline.json");

pub struct Baseline;

impl Baseline {
    pub fn allowances() -> Result<BTreeMap<String, BTreeMap<String, i64>>, ToolError> {
        let document: Value = serde_json::from_str(BASELINE_JSON).map_err(|error| {
            ToolError::message(format!(
                "Cannot decode swift-maintainability-baseline.json: {error}"
            ))
        })?;
        let declarations = document
            .get("declarations")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                ToolError::message(
                    "Missing bundled resource swift-maintainability-baseline.json",
                )
            })?;
        let mut allowances: BTreeMap<String, BTreeMap<String, i64>> = BTreeMap::new();
        for (identity, entry) in declarations {
            let Some(entry) = entry.as_object() else { continue };
            // Only numeric members are allowances; `reason` is documentation and
            // is skipped exactly as the Swift decoder skipped non-`Int` values.
            let values: BTreeMap<String, i64> = entry
                .iter()
                .filter_map(|(key, value)| value.as_i64().map(|number| (key.clone(), number)))
                .collect();
            allowances.insert(identity.clone(), values);
        }
        Ok(allowances)
    }
}

#[cfg(test)]
mod tests {
    use super::Baseline;

    #[test]
    fn the_baseline_loads_numeric_allowances_only() {
        let allowances = Baseline::allowances().expect("the bundled baseline decodes");
        assert_eq!(allowances.len(), 17, "the recorded debt list is frozen");
        for entry in allowances.values() {
            assert!(
                (1..=3).contains(&entry.len()),
                "an entry carries one to three metrics"
            );
            assert!(
                !entry.contains_key("reason"),
                "non-numeric fields must not load"
            );
            for (metric, value) in entry {
                assert!(
                    ["stored_properties", "initializer_parameters", "initializer_assignments"]
                        .contains(&metric.as_str())
                );
                assert!(*value > 0);
            }
        }
    }

    #[test]
    fn known_debt_entries_are_present() {
        let allowances = Baseline::allowances().unwrap();
        let entry = allowances
            .get("Engine/Sources/AIRuntime/Semantic/SceneSemanticSnapshot.swift::SceneSemanticSnapshot.Entity")
            .expect("the largest recorded declaration");
        assert_eq!(entry.get("stored_properties"), Some(&107));
    }
}
