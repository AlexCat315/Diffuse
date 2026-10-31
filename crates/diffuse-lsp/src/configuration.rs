//! `LanguageServerConfiguration` — how to launch and initialise a server.

use std::path::PathBuf;

use cove_system::command::ProcessCommand;

use crate::lsp::transport::LanguageServerTransport;

/// How a client connects to its server. Swift defaulted this to `nil`, meaning
/// "spawn a process".
pub type ConnectHook = Box<dyn Fn(&ProcessCommand) -> Result<LanguageServerTransport, String> + Send + Sync>;

pub struct LanguageServerConfiguration {
    pub command: ProcessCommand,
    pub workspace: PathBuf,
    /// Further roots the server serves beside `workspace`, such as the folder of
    /// a package the user is editing.
    pub additional_workspaces: Vec<PathBuf>,
    pub initialization_options: Option<Vec<u8>>,
    /// Answers `workspace/configuration`: a JSON object keyed by section, whose
    /// dotted names walk nested objects. Sections it lacks answer `null`.
    pub settings: Option<Vec<u8>>,
    /// Overrides process spawning, used by tests and by hosts with their own
    /// transport.
    pub connect: Option<ConnectHook>,
}

impl LanguageServerConfiguration {
    /// Swift's initializer set `command` and `workspace` only; every optional
    /// field kept its default.
    #[inline]
    pub fn new(command: ProcessCommand, workspace: PathBuf) -> Self {
        LanguageServerConfiguration {
            command,
            workspace,
            additional_workspaces: Vec::new(),
            initialization_options: None,
            settings: None,
            connect: None,
        }
    }

    /// Every workspace root the server serves, in Swift's order: the primary
    /// workspace first, then the additional roots.
    pub fn workspace_roots(&self) -> Vec<PathBuf> {
        let mut roots = Vec::with_capacity(1 + self.additional_workspaces.len());
        roots.push(self.workspace.clone());
        roots.extend(self.additional_workspaces.iter().cloned());
        roots
    }

    /// `workspaceFolders` as LSP wants them: `{uri, name}` with a standardized
    /// absolute `file:` URI and the last path component as the name.
    pub fn workspace_folders(&self) -> Vec<WorkspaceFolder> {
        self.workspace_roots()
            .into_iter()
            .map(|root| {
                let name = root
                    .file_name()
                    .map(|value| value.to_string_lossy().into_owned())
                    .unwrap_or_default();
                WorkspaceFolder { uri: file_uri(&root), name }
            })
            .collect()
    }
}

/// One LSP workspace folder entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceFolder {
    pub uri: String,
    pub name: String,
}

/// `URL.standardizedFileURL.absoluteString` for a filesystem path.
pub fn file_uri(path: &std::path::Path) -> String {
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    // Percent-encode the characters LSP requires to differ from a bare path.
    let mut encoded = String::from("file://");
    for byte in absolute.to_string_lossy().bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(byte as char);
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    encoded
}
