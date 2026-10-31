//! Rejects new oversized Swift types and initializers; reports existing debt.
//!
//! This is a structural guard, not a replacement for Swift's parser or code
//! review. It ignores comments, strings, computed/static properties, and nested
//! function bodies when counting a type's stored properties.

use super::baseline::Baseline;
use super::inventory::Inventory;
use crate::support::terminal::{Terminal, ToolError};

pub struct Maintainability;

impl Maintainability {
    pub const USAGE: &'static str = "\
usage: cove-dev maintainability [-h] [--report]

Reject new oversized Swift types and initializers; report existing debt.
This is a structural guard, not a replacement for Swift's parser or code
review. It ignores comments, strings, computed/static properties, and
nested function bodies when counting a type's stored properties.

options:
  -h, --help  show this help message and exit
  --report    also list existing oversized declarations";

    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        let mut report = false;
        for argument in arguments {
            match argument.as_str() {
                "--report" => report = true,
                "-h" | "--help" => {
                    Terminal::info(Self::USAGE);
                    return Ok(());
                }
                other => {
                    return Err(ToolError::message(format!(
                        "unrecognized arguments: {other}"
                    )));
                }
            }
        }

        let baseline = Baseline::allowances()?;
        let result = Inventory::evaluate(&Inventory::declarations()?, &baseline);
        if report {
            for line in &result.debt {
                Terminal::info(line);
            }
        }
        if !result.violations.is_empty() {
            for violation in &result.violations {
                Terminal::info(violation);
            }
            return Err(ToolError::message(
                "Split the declaration by responsibility; do not raise the baseline to silence this check.",
            ));
        }
        Terminal::info(&format!(
            "Swift maintainability check passed; {} existing over-limit metrics cannot grow.",
            result.debt.len()
        ));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::Maintainability;

    #[test]
    fn help_prints_the_usage() {
        assert!(Maintainability::run(&["--help".to_string()]).is_ok());
        assert!(Maintainability::run(&["-h".to_string()]).is_ok());
    }

    #[test]
    fn unknown_arguments_are_rejected() {
        let error = Maintainability::run(&["--fix".to_string()]).unwrap_err();
        assert_eq!(error.to_string(), "unrecognized arguments: --fix");
    }
}
