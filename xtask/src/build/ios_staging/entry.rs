//! `IOSStaging/Entry.swift` — stages isolated iOS native dependencies without
//! replacing desktop artifacts.
//!
//! Replaces `scripts/bootstrap-ios.py`: it stages the pinned FFmpeg variant
//! for the requested iOS SDK/arch, then configures and builds the Engine
//! third-party CMake graph into `build/ios-*/` with an iOS sysroot.

use std::collections::BTreeMap;
use std::path::Path;

use crate::build::media_staging::entry::MediaStaging;
use crate::support::repository;
use crate::support::shell;
use crate::support::terminal::{Terminal, ToolError};

pub const USAGE: &str = "\
cove-dev ios-native [--sdk iphoneos|iphonesimulator] [--arch arm64|x86_64]

  --sdk      iOS SDK to target; defaults to iphonesimulator.
  --arch     Architecture to build; defaults to arm64. Devices require arm64.
";

pub enum IOSStaging {}

impl IOSStaging {
    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        let mut sdk = "iphonesimulator".to_string();
        let mut arch = "arm64".to_string();
        let mut index = 0;
        while index < arguments.len() {
            match arguments[index].as_str() {
                "-h" | "--help" => {
                    Terminal::info(USAGE);
                    return Ok(());
                }
                "--sdk" => sdk = value(arguments, &mut index)?,
                "--arch" => arch = value(arguments, &mut index)?,
                other => {
                    return Err(ToolError::message(format!(
                        "unrecognized arguments: {other}"
                    )));
                }
            }
            index += 1;
        }
        if sdk != "iphoneos" && sdk != "iphonesimulator" {
            return Err(ToolError::message(format!(
                "argument --sdk: invalid choice: '{sdk}' (choose from 'iphoneos', 'iphonesimulator')"
            )));
        }
        if arch != "arm64" && arch != "x86_64" {
            return Err(ToolError::message(format!(
                "argument --arch: invalid choice: '{arch}' (choose from 'arm64', 'x86_64')"
            )));
        }
        stage(&sdk, &arch)
    }
}

/// Runs the same build for the SDK/arch selected by the iOS application build.
#[cfg(not(target_os = "macos"))]
fn stage(_sdk: &str, _arch: &str) -> Result<(), ToolError> {
    Err(ToolError::message(
        "iOS builds require macOS; devices require arm64",
    ))
}

#[cfg(target_os = "macos")]
fn stage(sdk: &str, arch: &str) -> Result<(), ToolError> {
    if sdk == "iphoneos" && arch != "arm64" {
        return Err(ToolError::message(
            "iOS builds require macOS; devices require arm64",
        ));
    }
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    let root = repository::root();
    let sdk_root = match std::env::var_os("COVE_SDK_ROOT") {
        Some(path) if !path.is_empty() => repository::standardized(Path::new(&path)),
        _ => root.join("CoveUI"),
    };
    let engine_root = root.join("Engine");
    let variant = format!(
        "ios-{arch}{}",
        if sdk == "iphonesimulator" {
            "-simulator"
        } else {
            ""
        }
    );
    let vendor = repository::path("Engine/Media/vendor");
    if !MediaStaging::is_ready(&variant, &vendor) {
        MediaStaging::run(&["--platform".into(), variant.clone()])?;
    }
    let sysroot = shell::output(
        &[
            "xcrun".into(),
            "--sdk".into(),
            sdk.into(),
            "--show-sdk-path".into(),
        ],
        None,
        &environment,
        false,
    )?;
    shell::inherit(
        &[
            sdk_root.join("cove").display().to_string(),
            "setup".into(),
            "--ios".into(),
            "--sdk".into(),
            sdk.into(),
            "--arch".into(),
            arch.into(),
        ],
        None,
        &environment,
        None,
    )?;
    // Swift iterates a one-element package list (Engine only today); keeping
    // the loop leaves the CoveUI package as a one-line future addition.
    #[allow(clippy::single_element_loop)]
    for package in [&engine_root] {
        let build = package.join("build").join(&variant);
        let native = build.join("native");
        let command = vec![
            "cmake".into(),
            "-S".into(),
            package.join("third-party").display().to_string(),
            "-B".into(),
            native.display().to_string(),
            "-G".into(),
            "Ninja".into(),
            "-DCMAKE_BUILD_TYPE=Release".into(),
            "-DCMAKE_SYSTEM_NAME=iOS".into(),
            format!("-DCMAKE_OSX_SYSROOT={sysroot}"),
            format!("-DCMAKE_OSX_ARCHITECTURES={arch}"),
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0".into(),
            format!("-DCOVE_VENDOR_DIR={}", build.join("vendor").display()),
        ];
        // The Engine package resolves ocio_openexr from the staged artifact
        // root, so iOS must build and stage the EXR stack like every other
        // native dependency; a missing bundle breaks package resolution.
        let targets: Vec<String> = if *package == engine_root {
            vec!["stage_ocio_openexr".into()]
        } else {
            Vec::new()
        };
        shell::inherit(&command, None, &environment, None)?;
        let mut build_command = vec![
            "cmake".into(),
            "--build".into(),
            native.display().to_string(),
            "--parallel".into(),
            "4".into(),
            "--target".into(),
        ];
        build_command.extend(targets);
        shell::inherit(&build_command, None, &environment, None)?;
        shell::inherit(
            &[
                "cmake".into(),
                "--install".into(),
                native.display().to_string(),
                "--prefix".into(),
                build.join("install").display().to_string(),
            ],
            None,
            &environment,
            None,
        )?;
    }
    Ok(())
}

fn value(arguments: &[String], index: &mut usize) -> Result<String, ToolError> {
    *index += 1;
    if *index >= arguments.len() {
        return Err(ToolError::message(format!(
            "missing value for {}",
            arguments[*index - 1]
        )));
    }
    Ok(arguments[*index].clone())
}
