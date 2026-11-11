//! Diffuse build automation.
//!
//! Cove's commands (`setup`, `audit`, `package`, `run`, `android-prepare`,
//! `devices`) are served by `cove_package`. Commands that only exist in Diffuse
//! are dispatched here before the remaining arguments are handed to Cove:
//! `cove_package` exposes only `main()`/`cargo_main()`, and its `Cli`/`Command`
//! are private, so they cannot be extended in place.

mod build;
mod plugins;
mod support;
// Swift compiles RuntimeValidation only where `#if !os(Windows)` holds; the
// command reports "requires a macOS or Linux host" on Windows instead.
#[cfg(not(windows))]
mod validation;

pub mod json_format;

use std::path::PathBuf;
use std::process::ExitCode;

use crate::build::native_bootstrap::entry::NativeBootstrap;
use crate::build::plugin_staging::bun_staging::PluginStaging;
use crate::plugins::type_script_build::PluginBuild;
use crate::support::repository;

const PLUGIN_BUILD_USAGE: &str = "usage: cargo xtask plugin-build DIRECTORY [--output PATH]";

fn main() -> ExitCode {
    let mut arguments = std::env::args_os();
    let _program = arguments.next();
    match arguments
        .next()
        .as_deref()
        .and_then(std::ffi::OsStr::to_str)
    {
        Some("plugin-build") => plugin_build(),
        Some("plugins") => plugins(),
        Some("native-bootstrap") => native_bootstrap(),
        // `cove_package::main()` calls `Cli::parse()` on the process argv, so
        // the forwarded branch must leave argv untouched.
        _ => cove_package::main(),
    }
}

fn plugin_build() -> ExitCode {
    let mut directory: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut arguments = std::env::args_os().skip(2);
    while let Some(argument) = arguments.next() {
        let text = argument.to_string_lossy().into_owned();
        match text.as_str() {
            "--output" => match arguments.next() {
                Some(value) => output = Some(PathBuf::from(value)),
                None => return fail("plugin-build: --output needs a path"),
            },
            "-h" | "--help" => {
                println!("{PLUGIN_BUILD_USAGE}");
                return ExitCode::SUCCESS;
            }
            _ if directory.is_none() => directory = Some(PathBuf::from(text)),
            other => return fail(&format!("plugin-build: unexpected argument {other}")),
        }
    }
    let Some(directory) = directory else {
        return fail(PLUGIN_BUILD_USAGE);
    };
    let build = PluginBuild {
        directory,
        root: repository::root(),
        output,
    };
    match build.run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => fail(&error.to_string()),
    }
}

fn native_bootstrap() -> ExitCode {
    let arguments: Vec<String> = std::env::args_os()
        .skip(2)
        .map(|argument| argument.to_string_lossy().into_owned())
        .collect();
    match NativeBootstrap::run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => fail(&error.to_string()),
    }
}

fn plugins() -> ExitCode {
    let arguments: Vec<String> = std::env::args_os()
        .skip(2)
        .map(|argument| argument.to_string_lossy().into_owned())
        .collect();
    match PluginStaging::run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => fail(&error.to_string()),
    }
}

fn fail(text: &str) -> ExitCode {
    eprintln!("{text}");
    ExitCode::FAILURE
}
