//! `Editor/Sources/EditorCore/State/Workspace/EditorWorkbenchState.swift`.
//!
//! Workbench vocabulary and the issue targets console entries point at.

use std::collections::BTreeSet;
use std::path::Path;

use diffuse_plugin::Uuid;
use diffuse_render::core::frame::render_packet::RenderDrawableSize;
use diffuse_script::interop::component_registry_script_codec::scene_document_scripts;
use serde::{Deserialize, Serialize};

use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::scene::manifest::node::EditorSceneManifestNode;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorViewportMode {
    Scene,
    Game,
}

/// Which console tab is shown. Session state: Swift never encoded it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum EditorOutputTab {
    Logs,
    Problems,
    Build,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorGamePreviewResolution {
    Fit,
    #[serde(rename = "hd720")]
    Hd720,
    #[serde(rename = "fullHD")]
    FullHd,
    Portrait,
    Square,
}

impl EditorGamePreviewResolution {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorGamePreviewResolution; 5] = [
        EditorGamePreviewResolution::Fit,
        EditorGamePreviewResolution::Hd720,
        EditorGamePreviewResolution::FullHd,
        EditorGamePreviewResolution::Portrait,
        EditorGamePreviewResolution::Square,
    ];

    pub fn title(self) -> &'static str {
        match self {
            EditorGamePreviewResolution::Fit => "Fit Window",
            EditorGamePreviewResolution::Hd720 => "1280 × 720 · 16:9",
            EditorGamePreviewResolution::FullHd => "1920 × 1080 · 16:9",
            EditorGamePreviewResolution::Portrait => "720 × 1280 · 9:16",
            EditorGamePreviewResolution::Square => "1024 × 1024 · 1:1",
        }
    }

    pub fn size(self) -> Option<RenderDrawableSize> {
        match self {
            EditorGamePreviewResolution::Fit => None,
            EditorGamePreviewResolution::Hd720 => Some(RenderDrawableSize::new(1280, 720)),
            EditorGamePreviewResolution::FullHd => Some(RenderDrawableSize::new(1920, 1080)),
            EditorGamePreviewResolution::Portrait => Some(RenderDrawableSize::new(720, 1280)),
            EditorGamePreviewResolution::Square => Some(RenderDrawableSize::new(1024, 1024)),
        }
    }

    pub fn aspect_ratio(self) -> Option<f32> {
        self.size()
            .map(|size| size.width as f32 / size.height as f32)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorIssueTarget {
    Script { id: String, line: i64, column: i64 },
    Asset { id: String },
    Entity { id: u64 },
    File { path: String },
}

impl EditorIssueTarget {
    pub(crate) fn unresolved_binding_target(
        descriptions: &[String],
        manifest: &EditorSceneManifest,
    ) -> Option<EditorIssueTarget> {
        let descriptions: BTreeSet<&str> = descriptions.iter().map(String::as_str).collect();
        fn find(
            nodes: &[EditorSceneManifestNode],
            descriptions: &BTreeSet<&str>,
        ) -> Option<EditorIssueTarget> {
            for node in nodes {
                if let Some(bindings) = scene_document_scripts(&node.components)
                    && bindings.iter().any(|binding| {
                        let reference = binding.identifier.as_deref().unwrap_or("<no identifier>");
                        binding.is_enabled
                            && descriptions.contains(format!("{}: {reference}", node.name).as_str())
                    })
                {
                    return Some(EditorIssueTarget::Entity { id: node.id });
                }
                if let Some(target) = find(&node.children, descriptions) {
                    return Some(target);
                }
            }
            None
        }
        find(&manifest.roots, &descriptions)
    }

    pub fn compiler_diagnostic(
        script_id: &str,
        source_url: &Path,
        output: &str,
    ) -> EditorIssueTarget {
        let name = source_url
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if let Some((line, column)) = first_compiler_diagnostic(output, name) {
            return EditorIssueTarget::Script {
                id: script_id.to_string(),
                line: (line - 1).max(0),
                column: (column - 1).max(0),
            };
        }
        EditorIssueTarget::Script {
            id: script_id.to_string(),
            line: 0,
            column: 0,
        }
    }
}

/// The first `<name>:<line>:<column>: error:` run, mirroring the Swift pattern
/// `(?:^|\n)[^\n]*<name>:([0-9]+):([0-9]+):\s*error:`. The greedy prefix means
/// the *last* occurrence on a line wins, and the first line with one wins
/// overall.
fn first_compiler_diagnostic(output: &str, name: &str) -> Option<(i64, i64)> {
    if name.is_empty() {
        return None;
    }
    let mut line_start = 0usize;
    loop {
        let line_end = output[line_start..]
            .find('\n')
            .map(|offset| line_start + offset)
            .unwrap_or(output.len());
        let line = &output[line_start..line_end];
        let mut search_end = line.len();
        while let Some(index) = line[..search_end].rfind(name) {
            let rest = &output[line_start + index + name.len()..];
            if let Some(position) = parse_diagnostic_rest(rest) {
                return Some(position);
            }
            search_end = index;
        }
        if line_end == output.len() {
            return None;
        }
        line_start = line_end + 1;
    }
}

fn parse_diagnostic_rest(rest: &str) -> Option<(i64, i64)> {
    let rest = rest.strip_prefix(':')?;
    let line: String = rest
        .chars()
        .take_while(|character| character.is_ascii_digit())
        .collect();
    if line.is_empty() {
        return None;
    }
    let rest = rest.get(line.len()..)?;
    let rest = rest.strip_prefix(':')?;
    let column: String = rest
        .chars()
        .take_while(|character| character.is_ascii_digit())
        .collect();
    if column.is_empty() {
        return None;
    }
    let rest = rest.get(column.len()..)?;
    let rest = rest.strip_prefix(':')?;
    let rest = rest.trim_start_matches(|character: char| character.is_whitespace());
    if !rest.starts_with("error:") {
        return None;
    }
    Some((line.parse().ok()?, column.parse().ok()?))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorOperationKind {
    Importing,
    Exporting,
    PreparingRenderer,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorOperationStatus {
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorOperation {
    pub id: String,
    pub kind: EditorOperationKind,
    pub status: EditorOperationStatus,
    pub message: String,
    pub completed: i64,
    pub total: i64,
    pub next_step: Option<String>,
    pub target: Option<EditorIssueTarget>,
}

impl EditorOperation {
    /// The full memberwise initializer.
    pub fn new(
        id: impl Into<String>,
        kind: EditorOperationKind,
        status: EditorOperationStatus,
        message: impl Into<String>,
        completed: i64,
        total: i64,
        next_step: Option<String>,
        target: Option<EditorIssueTarget>,
    ) -> Self {
        EditorOperation {
            id: id.into(),
            kind,
            status,
            message: message.into(),
            completed,
            total,
            next_step,
            target,
        }
    }

    /// Swift's default arguments: a fresh UUID, `.running`, zero counts.
    pub fn with_defaults(kind: EditorOperationKind, message: impl Into<String>) -> Self {
        Self::new(
            diffuse_kernel::codable::new_uuid(),
            kind,
            EditorOperationStatus::Running,
            message,
            0,
            0,
            None,
            None,
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorScriptNavigationRequest {
    pub id: Uuid,
    pub script_id: String,
    pub line: i64,
    pub column: i64,
}

impl EditorScriptNavigationRequest {
    /// Swift's `init(scriptID:line:column:)` with its zero defaults.
    pub fn new(script_id: impl Into<String>) -> Self {
        Self::with_position(script_id, 0, 0)
    }

    /// The full initializer; both coordinates are clamped to `>= 0`.
    pub fn with_position(script_id: impl Into<String>, line: i64, column: i64) -> Self {
        EditorScriptNavigationRequest {
            id: Uuid::new(),
            script_id: script_id.into(),
            line: line.max(0),
            column: column.max(0),
        }
    }
}
