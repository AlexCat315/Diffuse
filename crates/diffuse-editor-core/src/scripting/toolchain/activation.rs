//! Translation of Editor/Sources/EditorCore/Scripting/Toolchain/Activation.swift.
//!
//! Swift modelled the steps as `@MainActor @Sendable () async throws -> Void`;
//! without an async runtime they are synchronous transitions the caller runs on
//! the UI thread.

use std::sync::Arc;

use super::resolution::SwiftToolchainError;

pub type ToolchainSuspend = Arc<dyn Fn() + Send + Sync>;
pub type ToolchainTransition = Arc<dyn Fn() -> Result<(), SwiftToolchainError> + Send + Sync>;

#[derive(Clone)]
pub struct ScriptToolchainActivation {
    pub suspend: ToolchainSuspend,
    pub activate: ToolchainTransition,
    pub recover: ToolchainTransition,
}

impl ScriptToolchainActivation {
    pub fn new(
        suspend: ToolchainSuspend,
        activate: ToolchainTransition,
        recover: ToolchainTransition,
    ) -> Self {
        ScriptToolchainActivation {
            suspend,
            activate,
            recover,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScriptToolchainLanguageIntent {
    pub suspended: bool,
    pub did_suspend: bool,
}
