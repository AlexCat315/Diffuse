//! Translation of Editor/Sources/EditorCore/Scripting/Toolchain/Activity.swift.

use super::installation::SwiftToolchainInstallProgress;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScriptToolchainActivity {
    Idle,
    Selecting,
    Installation(SwiftToolchainInstallProgress),
    Failed(String),
}

impl ScriptToolchainActivity {
    pub fn is_busy(&self) -> bool {
        match self {
            ScriptToolchainActivity::Selecting => true,
            ScriptToolchainActivity::Installation(progress) => matches!(
                progress,
                SwiftToolchainInstallProgress::Downloading { .. }
                    | SwiftToolchainInstallProgress::Verifying
                    | SwiftToolchainInstallProgress::Installing
            ),
            ScriptToolchainActivity::Idle | ScriptToolchainActivity::Failed(_) => false,
        }
    }
}
