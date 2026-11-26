//! Workspace and lifecycle cases from EditorProjectToolsTests.swift.

use std::fs;
use std::path::PathBuf;
use std::rc::Rc;

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_ai::tools::tool_policy::ToolCallOrigin;
use diffuse_intent::invocation::capability_invocation::{
    ConfirmationOption, ConfirmationQuestion, ConfirmationQuestionKind, ConfirmationRequestBatch,
    ConfirmationSeverity,
};
use diffuse_kernel::codable::new_uuid;
use serde_json::{Value, json};

use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;

struct Project {
    root: PathBuf,
    app: Rc<EditorApplication>,
}

impl Project {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("diffuse-project-tools-{}", new_uuid()));
        fs::create_dir(&root).expect("project directory");
        let app = EditorApplication::new(root.to_string_lossy().into_owned()).expect("editor");
        Self { root, app }
    }

    fn call(&self, name: &str, arguments: Value) -> Result<Value, EditorProjectToolError> {
        let output = self.app.execute_project_tool(
            name,
            &serde_json::to_vec(&arguments).expect("tool arguments"),
            ToolCallOrigin::Mcp,
        )?;
        Ok(serde_json::from_slice(&output).expect("tool response"))
    }
}

impl Drop for Project {
    fn drop(&mut self) {
        self.app.shutdown();
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn source_updates_preserve_identity_and_reject_stale_hashes_or_dirty_buffers() {
    let project = Project::new();
    let created = project
        .call(
            "write_script",
            json!({
                "filename": "Game.rs", "source": "first source", "expected_sha256": null
            }),
        )
        .expect("new script");
    let read = project
        .call("read_script", json!({"filename": "Game.rs"}))
        .expect("read");
    assert_eq!(read["source"], "first source");
    let hash = read["sha256"].as_str().expect("source hash");
    let replaced = project
        .call(
            "write_script",
            json!({
                "filename": "Game.rs", "source": "second source", "expected_sha256": hash
            }),
        )
        .expect("replace");
    assert_eq!(
        replaced["identifier"]
            .as_str()
            .expect("replacement identifier"),
        created["identifier"].as_str().expect("created identifier")
    );
    assert!(
        project
            .call(
                "write_script",
                json!({
                    "filename": "Game.rs", "source": "stale", "expected_sha256": hash
                })
            )
            .is_err()
    );

    let current = project
        .call("read_script", json!({"filename": "Game.rs"}))
        .expect("read");
    let scripts = &project.app.workstation.scripts;
    scripts.update_selected_source(TextBuffer::new("unsaved user draft"));
    assert!(project.call("write_script", json!({
        "filename": "Game.rs", "source": "overwrite", "expected_sha256": current["sha256"]
    })).is_err());
    assert_eq!(
        scripts
            .snapshot()
            .selected_document()
            .expect("selected document")
            .source
            .string_value(),
        "unsaved user draft"
    );
    assert_eq!(
        fs::read_to_string(project.root.join("Scripts/Game.rs")).expect("persisted source"),
        "second source"
    );
}

#[test]
fn project_tools_enforce_execution_trust_and_script_containment() {
    let project = Project::new();
    let outside = Project::new();
    project
        .call(
            "write_script",
            json!({"filename": "Game.rs", "source": "native code"}),
        )
        .expect("source without execution");
    assert!(project.call("compile_scripts", json!({})).is_err());
    assert!(project.call("trust_project", json!({})).is_err());
    assert!(
        !project
            .app
            .workstation
            .scripts
            .manager()
            .project_trust_state()
            .allows_execution()
    );

    let secret = outside.root.join("Outside.rs");
    fs::write(&secret, "outside").expect("outside script");
    let link = project.root.join("Scripts/Escape.rs");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&secret, &link).expect("escaped symlink");
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&secret, &link).expect("escaped symlink");
    let error = project
        .call("read_script", json!({"filename": "Escape.rs"}))
        .expect_err("read outside project must fail");
    assert_eq!(error.message, "Script escapes the project.");
}

#[test]
fn scene_review_and_playback_block_project_changes() {
    let project = Project::new();
    let mut question = ConfirmationQuestion::new(
        "delete",
        ConfirmationQuestionKind::ApproveDestructive,
        "Delete cube?",
        ConfirmationSeverity::Destructive,
        false,
        0.0,
    );
    question
        .options
        .push(ConfirmationOption::new("skip", "Skip"));
    project
        .app
        .store
        .dispatch(EditorAction::SetPendingConfirmationRequest(Some(
            ConfirmationRequestBatch::new("delete", "editor", "delete-cube", vec![question]),
        )));
    assert!(project.call("save_scene", json!({})).is_err());
    project.app.skip_pending_confirmation();

    project
        .call("set_playback_state", json!({"state": "playing"}))
        .expect("start play");
    assert!(
        project
            .call(
                "write_script",
                json!({"filename": "Game.rs", "source": "blocked"})
            )
            .is_err()
    );
    project
        .call("set_playback_state", json!({"state": "stopped"}))
        .expect("stop play");
    let saved = project.call("save_scene", json!({})).expect("save scene");
    assert_eq!(
        saved["path"],
        project
            .root
            .join(".cove/editor-scene-manifest.json")
            .to_string_lossy()
            .as_ref()
    );
}
