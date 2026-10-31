//! Validates application, platform and example dependency boundaries via
//! SwiftPM. The checks themselves live in `BoundaryChecks`; this is the CLI
//! entry point.

use super::checks::BoundaryChecks;
use crate::support::repository;
use crate::support::terminal::{Terminal, ToolError};

pub struct Boundaries;

impl Boundaries {
    /// The former tool took no arguments; the parameter exists for the CLI
    /// contract.
    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        if arguments == ["--help".to_string()] || arguments == ["-h".to_string()] {
            Terminal::info("cove-dev boundaries — validate package, application and template boundaries");
            return Ok(());
        }
        if !arguments.is_empty() {
            return Err(ToolError::message("boundaries takes no arguments"));
        }
        let environment: std::collections::BTreeMap<String, String> = std::env::vars().collect();
        let mut checks = BoundaryChecks::new(&repository::root(), &environment);
        checks.perform()
    }
}

#[cfg(test)]
mod tests {
    use super::Boundaries;

    #[test]
    fn help_is_accepted_and_arguments_are_rejected() {
        assert!(Boundaries::run(&["--help".to_string()]).is_ok());
        assert!(Boundaries::run(&["-h".to_string()]).is_ok());
        let error = Boundaries::run(&["--fix".to_string()]).unwrap_err();
        assert_eq!(error.to_string(), "boundaries takes no arguments");
    }
}
