//! The editor ↔ plugin-host wire protocol.
//!
//! Ported from `Engine/Sources/PluginRuntime/Host/PluginHostRPC.swift`.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::base64_data::Data;
use crate::contract::plugin_manifest::PluginImportPermission;
use crate::host::host_capability_call::HostCapabilityCall;
use crate::plugin_authorization::{PluginAuthorizationRecord, PluginExecutionBinding};
use crate::processes::contract::PluginProcessContext;
use crate::uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PluginHostMethod {
    Handshake,
    #[serde(rename = "validate_package")]
    ValidatePackage,
    Load,
    Discover,
    Prepare,
    Unload,
    #[serde(rename = "host_result")]
    HostResult,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHostRequest {
    pub id: Uuid,
    pub method: PluginHostMethod,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_path: Option<String>,
    /// Swift's synthesized key is `capabilityID`.
    #[serde(
        default,
        rename = "capabilityID",
        skip_serializing_if = "Option::is_none"
    )]
    pub capability_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<Data>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query_snapshot: Option<PluginQuerySnapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authorization: Option<PluginAuthorizationRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process_context: Option<PluginProcessContext>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_error: Option<String>,
}

impl PluginHostRequest {
    pub fn new(method: PluginHostMethod) -> Self {
        PluginHostRequest {
            id: Uuid::new(),
            method,
            plugin_path: None,
            capability_id: None,
            input: None,
            query_snapshot: None,
            authorization: None,
            process_context: None,
            host_error: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginQuerySnapshotError {
    #[error("plugin query snapshot exceeds 512 KiB")]
    TotalPayloadTooLarge,
    #[error("plugin query snapshot is missing {}", .0.raw_value())]
    MissingPayload(PluginImportPermission),
    #[error("plugin query snapshot contains invalid JSON for {}", .0.raw_value())]
    InvalidJSON(PluginImportPermission),
    #[error("plugin query request must be exactly {{\"operation\":\"snapshot\"}}")]
    InvalidRequest,
    #[error("plugin attempted to query an ungranted import: {0}")]
    ImportNotGranted(String),
}

/// Immutable, revision-bound query data supplied by the Editor for one plugin
/// preparation call. The PluginHost never receives SceneRuntime or project
/// service objects; Component imports can only retrieve one of these bounded
/// JSON snapshots.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginQuerySnapshot {
    pub id: Uuid,
    pub scene_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scene: Option<Data>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<Data>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub asset_metadata: Option<Data>,
}

impl PluginQuerySnapshot {
    pub const MAXIMUM_TOTAL_PAYLOAD_BYTES: usize = 512 * 1_024;
    pub const MAXIMUM_REQUEST_BYTES: usize = 16 * 1_024;

    pub fn new(scene_revision: u64) -> Self {
        PluginQuerySnapshot {
            id: Uuid::new(),
            scene_revision,
            scene: None,
            selection: None,
            asset_metadata: None,
        }
    }

    pub fn validate(
        &self,
        granted_imports: &BTreeSet<PluginImportPermission>,
    ) -> Result<(), PluginQuerySnapshotError> {
        let payloads: Vec<&Data> = [&self.scene, &self.selection, &self.asset_metadata]
            .into_iter()
            .flatten()
            .collect();
        // Swift used `addingReportingOverflow`; `checked_add` reports the same
        // overflow and the bound is far below `usize::MAX`.
        let mut total = 0usize;
        for payload in &payloads {
            total = total
                .checked_add(payload.len())
                .ok_or(PluginQuerySnapshotError::TotalPayloadTooLarge)?;
        }
        if total > Self::MAXIMUM_TOTAL_PAYLOAD_BYTES {
            return Err(PluginQuerySnapshotError::TotalPayloadTooLarge);
        }
        for permission in granted_imports {
            if !permission.is_snapshot() {
                continue;
            }
            let Some(payload) = self.payload(*permission) else {
                return Err(PluginQuerySnapshotError::MissingPayload(*permission));
            };
            let is_structured = serde_json::from_slice::<serde_json::Value>(payload.as_slice())
                .is_ok_and(|value| value.is_object() || value.is_array());
            if !is_structured {
                return Err(PluginQuerySnapshotError::InvalidJSON(*permission));
            }
        }
        Ok(())
    }

    pub fn response(
        &self,
        import_name: &str,
        request: &[u8],
        granted_imports: &BTreeSet<PluginImportPermission>,
    ) -> Result<Vec<u8>, PluginQuerySnapshotError> {
        // Swift required exactly `{"operation":"snapshot"}`: a one-key object.
        let request_ok = request.len() <= Self::MAXIMUM_REQUEST_BYTES
            && serde_json::from_slice::<serde_json::Value>(request).is_ok_and(|value| {
                value.as_object().is_some_and(|object| {
                    object.len() == 1
                        && object.get("operation").and_then(|value| value.as_str())
                            == Some("snapshot")
                })
            });
        if !request_ok {
            return Err(PluginQuerySnapshotError::InvalidRequest);
        }
        let Some(permission) = PluginImportPermission::from_raw_value(import_name) else {
            return Err(PluginQuerySnapshotError::ImportNotGranted(
                import_name.to_string(),
            ));
        };
        if !granted_imports.contains(&permission) {
            return Err(PluginQuerySnapshotError::ImportNotGranted(
                import_name.to_string(),
            ));
        }
        let Some(payload) = self.payload(permission) else {
            return Err(PluginQuerySnapshotError::MissingPayload(permission));
        };
        Ok(payload.0.clone())
    }

    pub fn payload(&self, permission: PluginImportPermission) -> Option<&Data> {
        match permission {
            PluginImportPermission::SceneQuery => self.scene.as_ref(),
            PluginImportPermission::SelectionQuery => self.selection.as_ref(),
            PluginImportPermission::AssetMetadataQuery => self.asset_metadata.as_ref(),
            PluginImportPermission::Process
            | PluginImportPermission::Http
            | PluginImportPermission::Editor
            | PluginImportPermission::Service => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHostResponse {
    pub id: Uuid,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Data>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_call: Option<PluginHostServiceCall>,
}

impl PluginHostResponse {
    pub fn new(id: Uuid, ok: bool) -> Self {
        PluginHostResponse {
            id,
            ok,
            payload: None,
            error: None,
            host_call: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHostServiceCall {
    pub permission: String,
    pub request: Data,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PluginPreparedCapabilityResult {
    Read(Vec<u8>),
    HostCalls(Vec<HostCapabilityCall>),
}

/// Narrow seam used by AIRuntime. Tests can provide a deterministic invoker;
/// production uses the isolated `PluginHostProcessClient` implementation.
pub trait PluginCapabilityInvoking {
    /// The process generation the invoker currently serves. Single-process
    /// invokers compare it against every binding; per-plugin invokers override
    /// `validate` instead.
    fn generation(&self) -> u64;

    /// Validates a binding against the process that currently owns its plugin.
    ///
    /// Processes are per plugin, so there is no meaningful host-wide
    /// generation: a restart invalidates one plugin, not all of them.
    fn validate(&self, binding: &PluginExecutionBinding) -> bool {
        binding.host_generation == self.generation()
    }

    fn prepare_capability(
        &self,
        binding: &PluginExecutionBinding,
        capability_id: &str,
        input: &[u8],
        query_snapshot: Option<&PluginQuerySnapshot>,
    ) -> Result<PluginPreparedCapabilityResult, crate::PluginError>;
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginHostFrameError {
    #[error("plugin host frame is too large")]
    FrameTooLarge,
    #[error("plugin host frame is incomplete")]
    IncompleteFrame,
    #[error("plugin host frame has trailing bytes")]
    TrailingBytes,
}

/// Four-byte big-endian length prefix followed by one JSON payload.
pub enum PluginHostFrameCodec {}

impl PluginHostFrameCodec {
    /// Transport bound only: each capability's own output limit still applies,
    /// 1 MiB for AI capabilities. Editor entry points carry whole tool output.
    pub const MAXIMUM_FRAME_BYTES: usize = 512 * 1_024 * 1_024;

    pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, crate::PluginError> {
        let payload = serde_json::to_vec(value)?;
        if payload.len() > Self::MAXIMUM_FRAME_BYTES {
            return Err(PluginHostFrameError::FrameTooLarge.into());
        }
        let length = u32::try_from(payload.len())
            .map_err(|_| PluginHostFrameError::FrameTooLarge)?
            .to_be_bytes();
        let mut frame = Vec::with_capacity(4 + payload.len());
        frame.extend_from_slice(&length);
        frame.extend_from_slice(&payload);
        Ok(frame)
    }

    pub fn decode<T: for<'de> Deserialize<'de>>(frame: &[u8]) -> Result<T, crate::PluginError> {
        if frame.len() < 4 {
            return Err(PluginHostFrameError::IncompleteFrame.into());
        }
        let length = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        if length > Self::MAXIMUM_FRAME_BYTES {
            return Err(PluginHostFrameError::FrameTooLarge.into());
        }
        let expected = 4 + length;
        if frame.len() < expected {
            return Err(PluginHostFrameError::IncompleteFrame.into());
        }
        if frame.len() != expected {
            return Err(PluginHostFrameError::TrailingBytes.into());
        }
        Ok(serde_json::from_slice(&frame[4..expected])?)
    }
}
