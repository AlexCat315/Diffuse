//! Translation of Editor/Sources/EditorUI/LaunchOptions.swift.
//!
//! Parses the editor's launch flags and RHI configuration before any window is
//! created. Arguments and environment are passed in so the same rules drive the
//! real process and the tests.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use cove_graphics::rhi::{DeviceConfig, GraphicsApi, platform_default_backends};
use serde::Deserialize;

pub struct EditorAppLaunchOptions {
    pub backend_config: DeviceConfig,
    pub project_directory: Option<String>,
    pub use_legacy: bool,
    pub validate_install: bool,
}

impl EditorAppLaunchOptions {
    pub fn load(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
    ) -> Result<Self, EditorAppLaunchError> {
        let command_line = ParsedCommandLine::parse(arguments)?;
        let config_path = command_line
            .config_path
            .clone()
            .or_else(|| environment.get("COVE_RHI_CONFIG").cloned());
        let file_config = match &config_path {
            Some(path) => Some(load_config_file(path)?),
            None => None,
        };

        let preferred_backends = resolve_preferred_backends(
            command_line.backend_list.as_deref(),
            environment.get("COVE_RHI_BACKENDS").map(String::as_str),
            file_config
                .as_ref()
                .and_then(|config| config.rhi.as_ref())
                .and_then(|rhi| rhi.preferred_backends.clone()),
        )?;

        let rhi = file_config.as_ref().and_then(|config| config.rhi.as_ref());
        let validation_enabled = rhi.and_then(|rhi| rhi.validation_enabled).unwrap_or(true);
        let frames_in_flight = rhi.and_then(|rhi| rhi.frames_in_flight).unwrap_or(2);
        let project_directory = command_line
            .project_directory
            .clone()
            .or_else(|| environment.get("COVE_PROJECT_DIR").cloned());

        let use_legacy =
            command_line.use_legacy || environment.get("COVE_LEGACY").is_some_and(|v| v == "1");

        Ok(EditorAppLaunchOptions {
            backend_config: DeviceConfig {
                preferred_backends,
                enable_validation: validation_enabled,
                frames_in_flight,
                ..DeviceConfig::default()
            },
            project_directory,
            use_legacy,
            validate_install: command_line.validate_install,
        })
    }

    /// Opens preferences as the primary window for focused configuration.
    pub fn settings_requested(arguments: &[String]) -> bool {
        arguments.iter().any(|argument| argument == "--settings")
    }

    /// Opt-in developer watch for enabled plugin packages. Watching never
    /// authorizes changed packages.
    pub fn watch_plugin_packages_requested(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
    ) -> bool {
        arguments
            .iter()
            .any(|argument| argument == "--watch-plugins")
            || environment
                .get("COVE_WATCH_PLUGINS")
                .is_some_and(|v| v == "1")
    }

    /// A plugin package to open for review over the editor window.
    pub fn review_plugin_path(arguments: &[String]) -> Option<String> {
        arguments
            .iter()
            .position(|argument| argument == "--review-plugin")
            .and_then(|index| arguments.get(index + 1))
            .cloned()
    }
}

/// The process's arguments and environment, including the program name.
fn process_arguments() -> Vec<String> {
    std::env::args().collect()
}

fn process_environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

impl EditorAppLaunchOptions {
    pub fn load_process() -> Result<Self, EditorAppLaunchError> {
        Self::load(&process_arguments(), &process_environment())
    }

    pub fn settings_requested_in_process() -> bool {
        Self::settings_requested(&process_arguments())
    }

    pub fn watch_plugin_packages_requested_in_process() -> bool {
        Self::watch_plugin_packages_requested(&process_arguments(), &process_environment())
    }

    pub fn review_plugin_path_in_process() -> Option<String> {
        Self::review_plugin_path(&process_arguments())
    }
}

fn resolve_preferred_backends(
    command_line_value: Option<&str>,
    environment_value: Option<&str>,
    file_value: Option<Vec<String>>,
) -> Result<Vec<GraphicsApi>, EditorAppLaunchError> {
    if let Some(command_line_value) = command_line_value {
        return parse_backend_list(command_line_value);
    }
    if let Some(environment_value) = environment_value {
        return parse_backend_list(environment_value);
    }
    if let Some(file_value) = file_value {
        return file_value
            .into_iter()
            .map(|name| parse_backend_name(&name))
            .collect();
    }
    Ok(platform_default_backends())
}

fn parse_backend_list(raw_value: &str) -> Result<Vec<GraphicsApi>, EditorAppLaunchError> {
    let names: Vec<&str> = raw_value
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .collect();
    if names.is_empty() {
        return Err(EditorAppLaunchError::InvalidBackendList(
            raw_value.to_string(),
        ));
    }
    names.into_iter().map(parse_backend_name).collect()
}

fn parse_backend_name(raw_name: &str) -> Result<GraphicsApi, EditorAppLaunchError> {
    match raw_name.to_ascii_lowercase().as_str() {
        "dx12" => Ok(GraphicsApi::Dx12),
        "metal" => Ok(GraphicsApi::Metal),
        "webgpu" => Ok(GraphicsApi::WebGpu),
        "vulkan" => Ok(GraphicsApi::Vulkan),
        _ => Err(EditorAppLaunchError::InvalidBackendName(
            raw_name.to_string(),
        )),
    }
}

fn load_config_file(
    path: &str,
) -> Result<EditorApplicationConfigurationFile, EditorAppLaunchError> {
    let data = std::fs::read_to_string(Path::new(path)).map_err(|error| {
        EditorAppLaunchError::InvalidConfigFile {
            path: path.to_string(),
            underlying: error.to_string(),
        }
    })?;
    serde_json::from_str(&data).map_err(|error| EditorAppLaunchError::InvalidConfigFile {
        path: path.to_string(),
        underlying: error.to_string(),
    })
}

struct ParsedCommandLine {
    backend_list: Option<String>,
    config_path: Option<String>,
    project_directory: Option<String>,
    use_legacy: bool,
    validate_install: bool,
}

impl ParsedCommandLine {
    fn parse(arguments: &[String]) -> Result<Self, EditorAppLaunchError> {
        let mut backend_list = None;
        let mut config_path = None;
        let mut project_directory = None;
        let mut use_legacy = false;
        let mut validate_install = false;

        let mut index = 1;
        while index < arguments.len() {
            let argument = &arguments[index];
            match argument.as_str() {
                "--rhi-backends" => {
                    index += 1;
                    let Some(value) = arguments.get(index) else {
                        return Err(EditorAppLaunchError::MissingValue(argument.clone()));
                    };
                    backend_list = Some(value.clone());
                }
                "--rhi-config" => {
                    index += 1;
                    let Some(value) = arguments.get(index) else {
                        return Err(EditorAppLaunchError::MissingValue(argument.clone()));
                    };
                    config_path = Some(value.clone());
                }
                "--project-dir" => {
                    index += 1;
                    let Some(value) = arguments.get(index) else {
                        return Err(EditorAppLaunchError::MissingValue(argument.clone()));
                    };
                    project_directory = Some(value.clone());
                }
                "--legacy" => use_legacy = true,
                "--validate-install" => validate_install = true,
                value if value.starts_with("--rhi-backends=") => {
                    backend_list = Some(value["--rhi-backends=".len()..].to_string());
                }
                value if value.starts_with("--rhi-config=") => {
                    config_path = Some(value["--rhi-config=".len()..].to_string());
                }
                value if value.starts_with("--project-dir=") => {
                    project_directory = Some(value["--project-dir=".len()..].to_string());
                }
                _ => {}
            }
            index += 1;
        }

        Ok(ParsedCommandLine {
            backend_list,
            config_path,
            project_directory,
            use_legacy,
            validate_install,
        })
    }
}

#[derive(Deserialize)]
struct EditorApplicationConfigurationFile {
    #[serde(default)]
    rhi: Option<RhiSection>,
}

#[derive(Deserialize)]
struct RhiSection {
    #[serde(default, rename = "preferredBackends")]
    preferred_backends: Option<Vec<String>>,
    #[serde(default, rename = "validationEnabled")]
    validation_enabled: Option<bool>,
    #[serde(default, rename = "framesInFlight")]
    frames_in_flight: Option<usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorAppLaunchError {
    MissingValue(String),
    InvalidBackendList(String),
    InvalidBackendName(String),
    InvalidConfigFile { path: String, underlying: String },
}

impl fmt::Display for EditorAppLaunchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EditorAppLaunchError::MissingValue(flag) => {
                write!(formatter, "missing value for {flag}")
            }
            EditorAppLaunchError::InvalidBackendList(raw_value) => {
                write!(formatter, "invalid backend list: {raw_value}")
            }
            EditorAppLaunchError::InvalidBackendName(name) => {
                write!(formatter, "unsupported backend name: {name}")
            }
            EditorAppLaunchError::InvalidConfigFile { path, underlying } => {
                write!(
                    formatter,
                    "failed to load config file at {path}: {underlying}"
                )
            }
        }
    }
}

impl std::error::Error for EditorAppLaunchError {}
