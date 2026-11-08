//! Ported from `Engine/Sources/AIRuntime/Tools/ProjectToolset.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::contracts::exports::{AgentTool, JsonSchema, SessionApiFormat};
use serde_json::Value;

/// Host-owned project operations. Scene mutations continue to use capability
/// drafts; these tools address the script workspace and durable project outputs.
pub enum ProjectToolset {}

pub type Executor = std::sync::Arc<
    dyn Fn(String, Vec<u8>) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>>
        + Send
        + Sync,
>;

fn object(properties: Vec<(&'static str, JsonSchema)>, required: Vec<&'static str>) -> JsonSchema {
    let properties: BTreeMap<String, JsonSchema> = properties
        .into_iter()
        .map(|(name, schema)| (name.to_string(), schema))
        .collect();
    let required: Vec<String> = required.into_iter().map(str::to_string).collect();
    JsonSchema::object(properties, required)
}

fn string(
    description: Option<&'static str>,
    minimum_length: Option<usize>,
    maximum_length: Option<usize>,
) -> JsonSchema {
    JsonSchema {
        description: description.map(str::to_string),
        ..JsonSchema::string(minimum_length, maximum_length)
    }
}

fn array_of(item: JsonSchema, maximum_items: Option<usize>) -> JsonSchema {
    JsonSchema::array_of(item, maximum_items)
}

impl ProjectToolset {
    fn filename() -> JsonSchema {
        JsonSchema {
            description: Some(
                "One top-level Swift filename, such as Game.swift. No directories.".to_string(),
            ),
            pattern: Some("^[A-Za-z_][A-Za-z0-9_-]*\\.swift$".to_string()),
            ..JsonSchema::string(Some(7), Some(128))
        }
    }

    fn project_path() -> JsonSchema {
        string(Some("Project-relative file path"), Some(1), Some(1024))
    }

    pub fn tools() -> Vec<AgentTool> {
        let mut tools = vec![
            AgentTool::new(
                "list_files",
                "List visible workspace files without opening or executing them.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "read_file",
                "Read a UTF-8 text/code document, including its unsaved buffer. Read before editing.",
                object(vec![("path", Self::project_path())], vec!["path"]),
                true,
            ),
            AgentTool::new(
                "write_file",
                "Save a UTF-8 text/code file without executing it. Existing files require the exact expected_text from read_file. Unsaved buffers and external edits are protected.",
                object(
                    vec![
                        ("path", Self::project_path()),
                        ("text", JsonSchema::string(Some(0), Some(262_144))),
                        ("expected_text", JsonSchema::string(Some(0), Some(262_144))),
                    ],
                    vec!["path", "text"],
                ),
                false,
            ),
            AgentTool::new(
                "get_media_timeline",
                "Read authored video cuts and export settings.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "add_media_clip",
                "Append a project video file to the timeline after inspecting its streams and duration.",
                object(vec![("path", Self::project_path())], vec!["path"]),
                false,
            ),
            AgentTool::new(
                "trim_media_clip",
                "Set a clip's source in-point and duration in seconds.",
                object(
                    vec![
                        ("index", JsonSchema::integer(Some(0.0), Some(255.0))),
                        ("start", JsonSchema::number(Some(0.0), None)),
                        ("duration", JsonSchema::number(Some(0.001), None)),
                    ],
                    vec!["index", "start", "duration"],
                ),
                false,
            ),
            AgentTool::new(
                "remove_media_clip",
                "Remove one cut from the timeline; source media is preserved.",
                object(
                    vec![("index", JsonSchema::integer(Some(0.0), Some(255.0)))],
                    vec!["index"],
                ),
                false,
            ),
            AgentTool::new(
                "save_media_timeline",
                "Save authored cuts to .cove/media.json.",
                object(Vec::new(), Vec::new()),
                false,
            ),
            AgentTool::new(
                "export_media",
                "Render the current cuts with FFmpeg to a new MP4 in Exports. Returns the actual output path or error.",
                object(Vec::new(), Vec::new()),
                false,
            ),
            AgentTool::new(
                "get_project_info",
                "Read project, playback, AI availability, script trust and pending review status.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "get_scripting_api",
                "Read the supported Swift gameplay API and usage examples before authoring scripts.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "get_runtime_state",
                "Inspect current gameplay entity count, unresolved scripts and values reported by ScriptContext.reportState. Use during play to verify actual behavior.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "list_scripts",
                "List stable script identifiers, source hashes and editor document status.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "read_script",
                "Read a project Swift source and its SHA-256. Read before modifying an existing file.",
                object(vec![("filename", Self::filename())], vec!["filename"]),
                true,
            ),
            AgentTool::new(
                "write_script",
                "Create or update one project Swift source. Does not execute it. Existing files require the expected_sha256 returned by read_script; unsaved editor buffers are protected.",
                object(
                    vec![
                        ("filename", Self::filename()),
                        (
                            "source",
                            string(
                                Some(
                                    "Complete UTF-8 Swift source defining GameScript: ScriptBehavior.",
                                ),
                                Some(1),
                                Some(262_144),
                            ),
                        ),
                        (
                            "expected_sha256",
                            string(
                                Some(
                                    "Required when replacing an existing source; omit for a new file.",
                                ),
                                Some(64),
                                Some(64),
                            ),
                        ),
                    ],
                    vec!["filename", "source"],
                ),
                false,
            ),
            AgentTool::new(
                "compile_scripts",
                "Compile and load trusted project scripts. Returns per-file success and compiler diagnostics. Project trust must be granted by the human in the Scripts panel.",
                object(Vec::new(), Vec::new()),
                false,
            ),
            AgentTool::new(
                "save_scene",
                "Save the current authored scene to this project's normal scene file after pending scene edits have been reviewed.",
                object(Vec::new(), Vec::new()),
                false,
            ),
            AgentTool::new(
                "export_project",
                "Export this project with the configured Player, checking scripts and executable compatibility. Returns the runnable artifact path or the actual failure.",
                object(Vec::new(), Vec::new()),
                false,
            ),
            AgentTool::new(
                "set_playback_state",
                "Play, pause or stop the current scene. Stop restores authored scene state.",
                object(
                    vec![(
                        "state",
                        JsonSchema {
                            allowed_values: vec![
                                diffuse_capability::contracts::exports::JsonSchemaScalar::String(
                                    "playing".to_string(),
                                ),
                                diffuse_capability::contracts::exports::JsonSchemaScalar::String(
                                    "paused".to_string(),
                                ),
                                diffuse_capability::contracts::exports::JsonSchemaScalar::String(
                                    "stopped".to_string(),
                                ),
                            ],
                            ..JsonSchema::string(None, None)
                        },
                    )],
                    vec!["state"],
                ),
                false,
            ),
            AgentTool::new(
                "get_console_messages",
                "Read recent editor diagnostics to inspect compile, export and runtime failures.",
                object(
                    vec![("limit", JsonSchema::integer(Some(1.0), Some(50.0)))],
                    Vec::new(),
                ),
                true,
            ),
            AgentTool::new(
                "vcs_status",
                "Read the project's version control state (Git or Lore): branch, ahead/behind counts, and staged and unstaged changes with repository-relative paths.",
                object(Vec::new(), Vec::new()),
                true,
            ),
            AgentTool::new(
                "vcs_diff",
                "Read unified diffs of working-tree changes against the last revision. Omit path for every change; output is truncated for large change sets.",
                object(
                    vec![(
                        "path",
                        string(
                            Some("Repository-relative path from vcs_status"),
                            Some(1),
                            Some(1024),
                        ),
                    )],
                    Vec::new(),
                ),
                true,
            ),
            AgentTool::new(
                "vcs_log",
                "Read recent revisions (id, summary, author, date) on the current branch.",
                object(
                    vec![("limit", JsonSchema::integer(Some(1.0), Some(100.0)))],
                    Vec::new(),
                ),
                true,
            ),
            AgentTool::new(
                "vcs_commit",
                "Commit changes with a message. Given paths, stages exactly those first; otherwise commits what is staged, or everything when nothing is staged. Never pushes. Commit only when the user asked for it.",
                object(
                    vec![
                        (
                            "message",
                            string(
                                Some("Commit message: imperative subject line, optional body."),
                                Some(1),
                                Some(4096),
                            ),
                        ),
                        (
                            "paths",
                            array_of(JsonSchema::string(Some(1), Some(1024)), Some(200)),
                        ),
                    ],
                    vec!["message"],
                ),
                false,
            ),
        ];
        tools.extend(cove_agent::ui_tools::Tools::tools());
        tools
    }

    pub fn response_tool() -> AgentTool {
        AgentTool::new(
            "respond",
            "Finish with a useful answer or report. Use for questions and completed project work; use submit_plan for unapplied scene drafts.",
            object(
                vec![("message", JsonSchema::string(Some(1), Some(16_384)))],
                vec!["message"],
            ),
            true,
        )
    }

    pub fn definition(named: &str) -> Option<AgentTool> {
        Self::tools()
            .into_iter()
            .chain(std::iter::once(Self::response_tool()))
            .find(|tool| tool.name == named)
    }

    pub fn provider_definitions(
        format: SessionApiFormat,
        allowed_names: Option<&BTreeSet<String>>,
    ) -> Vec<Value> {
        Self::tools()
            .into_iter()
            .chain(std::iter::once(Self::response_tool()))
            .filter(|tool| allowed_names.is_none_or(|names| names.contains(&tool.name)))
            .map(|tool| tool.provider_definition(format))
            .collect()
    }

    pub fn provider_definitions_with_defaults(format: SessionApiFormat) -> Vec<Value> {
        Self::provider_definitions(format, None)
    }
}
