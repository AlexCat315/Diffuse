//! Plugin runtime: package contract, contribution domains, host transport and
//! lifecycle. See MIGRATION.md §5.
//!
//! Ported from `Engine/Sources/PluginRuntime`. The Swift target declared no
//! umbrella type; this crate root holds the module tree plus the two shared
//! vocabularies the Swift files each defined locally:
//!
//! * [`Uuid`] stands in for Foundation's `UUID` (v4, uppercase, hyphenated when
//!   encoded).
//! * [`data`] carries Swift's `Data` with its base64 `Codable` spelling.
//! * [`pattern`] is the regular-expression subset the Swift code validated and
//!   matched with `NSRegularExpression`.

pub mod base64_data;
pub mod contract;
pub mod contribution;
pub mod host;
pub mod lifecycle;
pub mod network;
pub mod pattern;
pub mod plugin_authorization;
pub mod processes;
pub mod swift_manifest_json;
#[cfg(test)]
mod tests;
pub mod uuid;

pub use uuid::Uuid;

/// Every failure a plugin operation can surface.
///
/// Swift's `throws` was untyped and the code defined one `Error` enum per
/// concern (`PluginManifestValidationError`, `PluginPackageError`,
/// `PluginManagerError`, …), letting a caller catch whichever it expected. Rust
/// needs one concrete error type per signature, so functions that cross concern
/// boundaries return this union while the individual enums stay intact and
/// keep their exact case sets. Call sites that need a specific failure match on
/// the variant, which is how the Swift `catch PluginManagerError.runtimeUnavailable`
/// spells in Rust.
#[derive(Debug, thiserror::Error)]
pub enum PluginError {
    #[error(transparent)]
    Manifest(#[from] contract::plugin_manifest::PluginManifestValidationError),
    #[error(transparent)]
    Contract(#[from] contract::plugin_contract::PluginContractError),
    #[error(transparent)]
    Package(#[from] contract::plugin_package::PluginPackageError),
    #[error(transparent)]
    Requirements(#[from] contract::requirements::UnmetPluginRequirements),
    #[error(transparent)]
    RequiredStillNeeded(#[from] contract::requirements::RequiredPluginStillNeeded),
    #[error(transparent)]
    Authorization(#[from] plugin_authorization::PluginAuthorizationError),
    #[error(transparent)]
    CapabilityValidation(#[from] plugin_authorization::PluginCapabilityValidationError),
    #[error(transparent)]
    CapabilityRegistry(#[from] plugin_authorization::PluginCapabilityRegistryError),
    #[error(transparent)]
    Manager(#[from] lifecycle::status::PluginManagerError),
    #[error(transparent)]
    Runtime(#[from] lifecycle::status::PluginRuntimeError),
    #[error(transparent)]
    HostClient(#[from] host::plugin_host_process_client::PluginHostClientError),
    #[error(transparent)]
    HostFrame(#[from] host::plugin_host_rpc::PluginHostFrameError),
    #[error(transparent)]
    QuerySnapshot(#[from] host::plugin_host_rpc::PluginQuerySnapshotError),
    #[error(transparent)]
    Bun(#[from] host::bun_runtime::BunRuntimeError),
    #[error(transparent)]
    Composition(#[from] host::host_capability_call::PluginCompositionError),
    #[error(transparent)]
    Http(#[from] network::http::PluginHTTPError),
    #[error(transparent)]
    HttpTransport(#[from] network::transfers::PluginHTTPTransportError),
    #[error(transparent)]
    Process(#[from] processes::contract::PluginProcessError),
    #[error(transparent)]
    Workbench(#[from] contribution::workbench::command::PluginWorkbenchResultError),
    #[error(transparent)]
    Registry(#[from] diffuse_capability::capability_registry::CapabilityRegistryIntegrityError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("invalid base64 payload")]
    InvalidBase64,
}

pub type PluginResult<T> = Result<T, PluginError>;
