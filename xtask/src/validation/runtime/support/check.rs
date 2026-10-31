//! Assertion helpers so a failed check reads like the Python `assert …` it was
//! ported from while still surfacing through `ToolError`.

use crate::support::terminal::ToolError;
use std::fmt::Display;

pub struct Check;

impl Check {
    pub fn require(condition: bool, message: impl FnOnce() -> String) -> Result<(), ToolError> {
        if condition {
            Ok(())
        } else {
            Err(ToolError::message(message()))
        }
    }

    /// `assert a == b, object` — the object is the failure message, as in the
    /// MCP validations.
    pub fn equal<T: PartialEq + Display>(
        actual: T,
        expected: T,
        context: impl FnOnce() -> String,
    ) -> Result<(), ToolError> {
        if actual == expected {
            Ok(())
        } else {
            Err(ToolError::message(format!(
                "Expected {expected}, got {actual}: {}",
                context()
            )))
        }
    }

    pub fn contains(
        text: &str,
        needle: &str,
        context: impl FnOnce() -> String,
    ) -> Result<(), ToolError> {
        if text.contains(needle) {
            Ok(())
        } else {
            Err(ToolError::message(format!(
                "Expected {} in {}",
                quote_json(needle),
                context()
            )))
        }
    }
}

/// `JSON.text(_:)` for a bare string: compact JSON with sorted keys.
fn quote_json(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| format!("{value:?}"))
}

#[cfg(test)]
mod tests {
    use super::Check;

    #[test]
    fn require_reports_the_message() {
        assert!(Check::require(true, || "unused".into()).is_ok());
        let error = Check::require(false, || "nope".into()).unwrap_err();
        assert_eq!(error.to_string(), "nope");
    }

    #[test]
    fn equal_reports_both_values_and_context() {
        assert!(Check::equal(2, 2, || "same".into()).is_ok());
        let error = Check::equal(1, 2, || "counts".into()).unwrap_err();
        assert_eq!(error.to_string(), "Expected 2, got 1: counts");
    }

    #[test]
    fn contains_quotes_the_needle() {
        assert!(Check::contains("abc", "b", || "unused".into()).is_ok());
        let error = Check::contains("abc", "z", || "logs".into()).unwrap_err();
        assert_eq!(error.to_string(), "Expected \"z\" in logs");
    }
}
