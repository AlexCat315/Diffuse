//! `Editor/Sources/EditorCore/Application/Plugins/EditorPluginCapabilityError.swift`.

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EditorPluginCapabilityError {
    #[error(
        "The trusted DiffusePluginHost executable is unavailable. Rebuild or reinstall the Editor."
    )]
    PluginHostUnavailable,
    #[error("Wait for the current plugin update to finish.")]
    PluginUpdateInProgress,
    #[error("Plugin '{0}' is not enabled.")]
    PluginNotEnabled(String),
    #[error("No inspected plugin is waiting for approval.")]
    NoPendingPluginApproval,
    #[error("The plugin plan is missing its capability exposure snapshot.")]
    MissingExposureSnapshot,
    #[error(
        "The scene changed while preparing plugin data (expected {expected}, actual {actual})."
    )]
    SceneRevisionChanged { expected: u64, actual: u64 },
    /// The plugin declares components but returned something other than a read payload.
    #[error("Plugin capability '{0}' must return a read payload of component descriptions.")]
    UnexpectedComponentDeclarationResult(String),
    #[error(
        "Plugin '{0}' declared components the host rejected. Its other capabilities stay enabled."
    )]
    InvalidComponentDeclaration(String),
    /// The on-disk package no longer matches its stored authorization; the
    /// user must re-authorize the new build through the management flow.
    #[error(
        "Plugin '{0}' changed on disk since it was authorized. Review and authorize the new build in Settings, then enable it again."
    )]
    PluginAuthorizationStale(String),
}
