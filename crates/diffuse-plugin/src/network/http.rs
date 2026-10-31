//! The HTTP request vocabulary a package can ask the host to perform.
//!
//! Ported from `Engine/Sources/PluginRuntime/Network/HTTP.swift`. MIGRATION.md
//! gap G4 maps `URLSession` to `cove-http`; nothing in this file performs I/O —
//! it is the persisted request/response shape and the permission rule, exactly
//! as the Swift file was.

pub use crate::base64_data::Data;

use std::fmt;

use serde::{Deserialize, Serialize};

/// One request a plugin asks the host to perform on its behalf. The host owns
/// the socket, the redirect policy and the response bound; a plugin never sees a
/// transport handle.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHTTPMessage {
    pub method: Method,
    pub url: String,
    #[serde(default)]
    pub headers: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<Data>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Method {
    #[serde(rename = "GET")]
    Get,
    #[serde(rename = "POST")]
    Post,
    #[serde(rename = "PUT")]
    Put,
    #[serde(rename = "PATCH")]
    Patch,
    #[serde(rename = "DELETE")]
    Delete,
}

impl Method {
    /// Swift declared `String` raw values; `CaseIterable` order is this order.
    pub const ALL: [Method; 5] = [
        Method::Get,
        Method::Post,
        Method::Put,
        Method::Patch,
        Method::Delete,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Put => "PUT",
            Method::Patch => "PATCH",
            Method::Delete => "DELETE",
        }
    }
}

impl PluginHTTPMessage {
    pub fn new(method: Method, url: impl Into<String>) -> Self {
        PluginHTTPMessage {
            method,
            url: url.into(),
            headers: std::collections::BTreeMap::new(),
            body: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHTTPResponse {
    pub status: i64,
    #[serde(default)]
    pub headers: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub body: Data,
}

impl PluginHTTPResponse {
    pub fn new(status: i64) -> Self {
        PluginHTTPResponse {
            status,
            headers: std::collections::BTreeMap::new(),
            body: Data::new(),
        }
    }
}

/// A transfer outlives the request that started it, so the plugin host's serial
/// request loop never waits on the network. `poll` returns the response once it
/// is ready.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHTTPRequest {
    pub operation: Operation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<crate::uuid::Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<PluginHTTPMessage>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    Start,
    Poll,
    Cancel,
}

impl PluginHTTPRequest {
    pub fn new(operation: Operation) -> Self {
        PluginHTTPRequest {
            operation,
            permission: None,
            handle: None,
            message: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHTTPUpdate {
    pub handle: crate::uuid::Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<i64>,
    #[serde(default)]
    pub headers: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub body: Data,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

impl PluginHTTPUpdate {
    pub fn new(handle: crate::uuid::Uuid) -> Self {
        PluginHTTPUpdate {
            handle,
            status: None,
            headers: std::collections::BTreeMap::new(),
            body: Data::new(),
            failure: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginHTTPError {
    #[error("plugin was not granted network access")]
    NotAuthorized,
    #[error("invalid HTTP request")]
    InvalidRequest,
    #[error("HTTP host '{0}' is not allowed for this plugin")]
    DomainDenied(String),
    #[error("HTTP scheme '{0}' is not allowed")]
    SchemeDenied(String),
    #[error("HTTP response exceeds the host bound")]
    ResponseTooLarge,
    #[error("plugin exceeded its concurrent transfer limit")]
    TransferLimit,
    #[error("HTTP transfer handle is not active")]
    InvalidHandle,
    #[error("HTTP request failed: {0}")]
    RequestFailed(String),
}

impl fmt::Display for Method {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.raw_value())
    }
}

/// Domains and limits a package is allowed to reach. Declared in `plugin.json`
/// under `host.http`, so a package cannot widen its own reach at call time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHTTPPermission {
    pub id: String,
    pub hosts: Vec<String>,
    #[serde(default = "default_allows_subdomains")]
    pub allows_subdomains: bool,
    #[serde(default)]
    pub allows_insecure_localhost: bool,
    #[serde(default = "default_maximum_response_bytes")]
    pub maximum_response_bytes: i64,
    #[serde(default = "default_timeout_milliseconds")]
    pub timeout_milliseconds: i64,
}

fn default_allows_subdomains() -> bool {
    true
}

fn default_maximum_response_bytes() -> i64 {
    8 * 1_024 * 1_024
}

fn default_timeout_milliseconds() -> i64 {
    30_000
}

impl PluginHTTPPermission {
    pub fn new(id: impl Into<String>, hosts: Vec<String>) -> Self {
        PluginHTTPPermission {
            id: id.into(),
            hosts,
            allows_subdomains: true,
            allows_insecure_localhost: false,
            maximum_response_bytes: 8 * 1_024 * 1_024,
            timeout_milliseconds: 30_000,
        }
    }

    /// `*.example.com` matches subdomains only; a bare host matches exactly.
    pub fn allows(&self, host: &str) -> bool {
        let host = host.to_lowercase();
        self.hosts.iter().any(|rule| {
            let rule = rule.to_lowercase();
            if let Some(suffix) = rule.strip_prefix("*.") {
                return self.allows_subdomains && host.ends_with(&format!(".{suffix}"));
            }
            host == rule
        })
    }
}
