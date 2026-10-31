//! The process request/response vocabulary a package can use.
//!
//! Ported from `Engine/Sources/PluginRuntime/Processes/Contract.swift`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::base64_data::Data;
use crate::uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginProcessContext {
    pub workspace: PathBuf,
    #[serde(default)]
    pub executables: BTreeMap<String, PathBuf>,
}

impl PluginProcessContext {
    pub fn new(workspace: PathBuf) -> Self {
        PluginProcessContext {
            workspace,
            executables: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginProcessRequest {
    pub operation: Operation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<String>,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Data>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    Start,
    Poll,
    Write,
    CloseInput,
    Stop,
}

impl PluginProcessRequest {
    pub fn new(operation: Operation) -> Self {
        PluginProcessRequest {
            operation,
            permission: None,
            arguments: Vec::new(),
            environment: BTreeMap::new(),
            handle: None,
            input: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginProcessUpdate {
    pub handle: Uuid,
    #[serde(default)]
    pub stdout: Data,
    #[serde(default)]
    pub stderr: Data,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_status: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resident_memory_bytes: Option<u64>,
}

impl PluginProcessUpdate {
    pub fn new(handle: Uuid) -> Self {
        PluginProcessUpdate {
            handle,
            stdout: Data::new(),
            stderr: Data::new(),
            exit_status: None,
            failure: None,
            resident_memory_bytes: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginProcessError {
    #[error("plugin was not granted process access")]
    NotAuthorized,
    #[error("process command '{0}' is not bound for this plugin")]
    CommandNotBound(String),
    #[error("process arguments are not allowed")]
    ArgumentsDenied,
    #[error("process environment is not allowed")]
    EnvironmentDenied,
    #[error("process handle is not active")]
    InvalidHandle,
    #[error("plugin exceeded its concurrent process limit")]
    ProcessLimit,
    #[error("invalid process request")]
    InvalidRequest,
}
