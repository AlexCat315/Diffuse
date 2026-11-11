//! Minimal `argparse`-shaped option reader, ported from
//! `Tools/Developer/Sources/Build/PluginStaging/Arguments.swift`.

use crate::support::terminal::ToolError;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// Long options take a value as `--name value` or `--name=value`, switches are
/// `--name`, and `-h/--help` records the `--help` flag. Positional tokens are
/// reported separately.
#[derive(Debug)]
pub struct FlagParser {
    arguments: Vec<String>,
    valued: BTreeSet<String>,
    switches: BTreeSet<String>,
    index: usize,
    pub values: BTreeMap<String, String>,
    pub flags: BTreeSet<String>,
    pub positionals: Vec<String>,
}

impl FlagParser {
    pub fn new(arguments: &[String], valued: &[&str], switches: &[&str]) -> Self {
        FlagParser {
            arguments: arguments.to_vec(),
            valued: valued.iter().map(|name| (*name).to_string()).collect(),
            switches: switches.iter().map(|name| (*name).to_string()).collect(),
            index: 0,
            values: BTreeMap::new(),
            flags: BTreeSet::new(),
            positionals: Vec::new(),
        }
    }

    pub fn parse(&mut self) -> Result<(), ToolError> {
        while self.index < self.arguments.len() {
            let argument = self.arguments[self.index].clone();
            self.index += 1;
            if argument == "-h" || argument == "--help" {
                self.flags.insert("--help".to_string());
                continue;
            }
            if !argument.starts_with("--") {
                self.positionals.push(argument);
                continue;
            }
            let body = &argument[2..];
            let (name, inline) = match body.find('=') {
                Some(equals) => (&body[..equals], Some(body[equals + 1..].to_string())),
                None => (body, None),
            };
            let option = format!("--{name}");
            if self.switches.contains(&option) {
                if let Some(inline) = inline {
                    return Err(ToolError::message(format!(
                        "argument {option}: ignored explicit argument '{inline}'"
                    )));
                }
                self.flags.insert(option);
            } else if self.valued.contains(&option) {
                match inline {
                    Some(inline) => {
                        self.values.insert(option, inline);
                    }
                    None => {
                        let Some(value) = self.arguments.get(self.index) else {
                            return Err(ToolError::message(format!(
                                "argument {option}: expected one argument"
                            )));
                        };
                        self.values.insert(option, value.clone());
                        self.index += 1;
                    }
                }
            } else {
                return Err(ToolError::message(format!(
                    "unrecognized arguments: {argument}"
                )));
            }
        }
        Ok(())
    }
}

/// Makes a possibly relative command-line path absolute against the caller's
/// working directory, matching `pathlib.Path(...).resolve()`.
pub fn absolute_path(path: &str) -> PathBuf {
    let url = Path::new(path);
    if url.is_absolute() {
        return crate::support::repository::standardized(url);
    }
    let current = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    crate::support::repository::standardized(&current.join(url))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(arguments: &[&str]) -> Result<FlagParser, ToolError> {
        let arguments: Vec<String> = arguments.iter().map(|value| value.to_string()).collect();
        let mut parser = FlagParser::new(&arguments, &["--platform", "--cache"], &["--check"]);
        parser.parse()?;
        Ok(parser)
    }

    #[test]
    fn valued_options_accept_both_spellings() {
        let parser = parse(&["--platform", "linux-x86_64", "--cache=/tmp/bun"]).unwrap();
        assert_eq!(parser.values["--platform"], "linux-x86_64");
        assert_eq!(parser.values["--cache"], "/tmp/bun");
    }

    #[test]
    fn switches_reject_inline_values_and_record_help() {
        let parser = parse(&["--check"]).unwrap();
        assert!(parser.flags.contains("--check"));
        let parser = parse(&["-h"]).unwrap();
        assert!(parser.flags.contains("--help"));
        assert_eq!(
            parse(&["--check=1"]).unwrap_err().to_string(),
            "argument --check: ignored explicit argument '1'"
        );
    }

    #[test]
    fn unknown_options_and_missing_values_fail() {
        assert_eq!(
            parse(&["--verbose"]).unwrap_err().to_string(),
            "unrecognized arguments: --verbose"
        );
        assert_eq!(
            parse(&["--platform"]).unwrap_err().to_string(),
            "argument --platform: expected one argument"
        );
    }

    #[test]
    fn positionals_keep_their_order() {
        let parser = parse(&["stage", "--check", "extra"]).unwrap();
        assert_eq!(parser.positionals, vec!["stage", "extra"]);
    }

    #[test]
    fn absolute_paths_resolve_against_the_working_directory() {
        let absolute = std::env::temp_dir().join("bun-cache");
        assert_eq!(absolute_path(&absolute.to_string_lossy()), absolute);
        let relative = absolute_path("bun-cache");
        assert!(relative.is_absolute());
        assert!(relative.ends_with("bun-cache"));
    }
}
