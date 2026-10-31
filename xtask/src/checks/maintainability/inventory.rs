//! Walks the first-party Swift packages, measures every declaration, and
//! compares it against the hard limits and the frozen baseline.

use super::structural_guard::{DeclarationMetrics, Metric, StructuralGuard};
use crate::support::files;
use crate::support::repository;
use crate::support::terminal::ToolError;
use std::collections::BTreeMap;
use std::path::PathBuf;

/// One measured declaration, keyed by `path::QualifiedType`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Declaration {
    pub identity: String,
    pub metrics: DeclarationMetrics,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Result_ {
    pub violations: Vec<String>,
    pub debt: Vec<String>,
}

pub struct Inventory;

impl Inventory {
    /// Package directories whose `Sources` trees are guarded, in scan order.
    pub const PACKAGE_ROOTS: [&'static str; 6] = [
        "Engine",
        "Engine/Media",
        "Editor",
        "Editor/Documents",
        "Tools/Developer",
        "Platforms/Android",
    ];

    /// Measures every guarded declaration in the checkout, keyed by
    /// `path::QualifiedType` in the order the checker first sees it.
    pub fn declarations() -> Result<Vec<Declaration>, ToolError> {
        // `OrderedMap` keeps the first-seen order while a duplicate key
        // overwrites in place, exactly like the Python dictionaries.
        let mut ordered = super::ordered_map::OrderedMap::new();
        for package in Self::PACKAGE_ROOTS {
            let sources = repository::path(package).join("Sources");
            if !sources.exists() {
                continue;
            }
            let mut paths: Vec<PathBuf> = files::files_in(&sources, false)
                .map_err(io_error)?
                .into_iter()
                .filter(|file| file.extension().map(|value| value == "swift").unwrap_or(false))
                .collect();
            paths.sort_by(|left, right| {
                let left: Vec<String> = left
                    .components()
                    .map(|part| part.as_os_str().to_string_lossy().into_owned())
                    .collect();
                let right: Vec<String> = right
                    .components()
                    .map(|part| part.as_os_str().to_string_lossy().into_owned())
                    .collect();
                left.cmp(&right)
            });
            for file in paths {
                let measured = StructuralGuard::measure(&files::text(&file).map_err(io_error)?);
                let relative = files::relative(&file, &repository::root());
                for (name, metrics) in measured.entries() {
                    ordered.insert(*metrics, &format!("{relative}::{name}"));
                }
            }
        }
        Ok(ordered
            .entries()
            .into_iter()
            .map(|(identity, metrics)| Declaration {
                identity: identity.to_string(),
                metrics: *metrics,
            })
            .collect())
    }

    /// Splits measured declarations into hard violations and frozen debt using
    /// the same `allowed = max(limit, baseline allowance)` rule as the Python
    /// guard.
    pub fn evaluate(
        declarations: &[Declaration],
        baseline: &BTreeMap<String, BTreeMap<String, i64>>,
    ) -> Result_ {
        let mut result = Result_::default();
        for declaration in declarations {
            for metric in Metric::ALL {
                let actual = declaration.metrics.get(metric);
                let allowance = baseline
                    .get(&declaration.identity)
                    .and_then(|entry| entry.get(metric.raw_value()))
                    .copied()
                    .unwrap_or_else(|| metric.limit());
                let allowed = metric.limit().max(allowance);
                if actual > allowed {
                    result.violations.push(format!(
                        "{}: {metric}={actual}, allowed={allowed}",
                        declaration.identity,
                        metric = metric.raw_value()
                    ));
                } else if actual > metric.limit() {
                    result.debt.push(format!(
                        "{}: {metric}={actual} (existing debt)",
                        declaration.identity,
                        metric = metric.raw_value()
                    ));
                }
            }
        }
        result
    }
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn declaration(name: &str, stored: i64) -> Declaration {
        Declaration {
            identity: name.to_string(),
            metrics: DeclarationMetrics {
                stored_properties: stored,
                ..DeclarationMetrics::default()
            },
        }
    }

    #[test]
    fn the_hard_limit_applies_without_a_baseline_entry() {
        let result = Inventory::evaluate(&[declaration("a::B", 21)], &BTreeMap::new());
        assert_eq!(result.violations.len(), 1);
        assert!(result.violations[0].contains("stored_properties=21, allowed=20"));
        assert!(result.debt.is_empty());
    }

    #[test]
    fn a_baseline_allowance_permits_existing_debt() {
        let baseline = BTreeMap::from([(
            "a::B".to_string(),
            BTreeMap::from([("stored_properties".to_string(), 58)]),
        )]);
        let result = Inventory::evaluate(&[declaration("a::B", 40)], &baseline);
        assert!(result.violations.is_empty());
        assert_eq!(result.debt.len(), 1);
        assert!(result.debt[0].contains("(existing debt)"));
        // Growing past the allowance is still a violation.
        let result = Inventory::evaluate(&[declaration("a::B", 59)], &baseline);
        assert_eq!(result.violations.len(), 1);
    }

    #[test]
    fn a_baseline_below_the_limit_cannot_weaken_it() {
        let baseline = BTreeMap::from([(
            "a::B".to_string(),
            BTreeMap::from([("stored_properties".to_string(), 5)]),
        )]);
        let result = Inventory::evaluate(&[declaration("a::B", 21)], &baseline);
        assert_eq!(result.violations.len(), 1);
    }

    #[test]
    fn at_the_limit_is_not_debt() {
        let result = Inventory::evaluate(&[declaration("a::B", 20)], &BTreeMap::new());
        assert!(result.violations.is_empty());
        assert!(result.debt.is_empty());
    }
}

#[cfg(test)]
mod checkout_tests {
    use super::*;
    use crate::checks::maintainability::baseline::Baseline;

    /// The guard must measure the real Swift tree and agree with the frozen
    /// baseline: every recorded debt entry still matches, and nothing new
    /// exceeds a hard limit.
    #[test]
    fn the_checkout_passes_the_guard_against_the_frozen_baseline() {
        let baseline = Baseline::allowances().expect("baseline");
        let declarations = Inventory::declarations().expect("declarations");
        assert!(
            declarations.len() > 1000,
            "expected the real Swift tree, measured {}",
            declarations.len()
        );
        let result = Inventory::evaluate(&declarations, &baseline);
        assert!(
            result.violations.is_empty(),
            "violations: {:#?}",
            result.violations
        );
        // The frozen debt must still be observed; a silent empty scan would
        // otherwise pass this test.
        assert!(!result.debt.is_empty());
        // A baseline key with no matching declaration is unused debt, and both
        // implementations ignore it: the Swift guard also only looks entries up
        // by the declarations it measured. `ViewportInfoBar` is such an entry —
        // the type was removed upstream while the frozen baseline kept the row.
        let identities: std::collections::BTreeSet<&str> =
            declarations.iter().map(|d| d.identity.as_str()).collect();
        let measured = baseline
            .keys()
            .filter(|key| identities.contains(key.as_str()))
            .count();
        assert_eq!(
            measured,
            baseline.keys().filter(|key| !key.starts_with("CoveUI/")).count() - 1,
            "exactly one non-SDK baseline entry is stale"
        );
    }
}
