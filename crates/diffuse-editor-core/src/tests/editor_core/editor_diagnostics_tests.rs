//! Ported from `Editor/Tests/EditorCoreTests/EditorDiagnosticsTests.swift`.

use std::cell::{Cell, RefCell};
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use cove_agent::ui_tools::Tools as UITools;
use cove_ui_compose::scene_core::{Node, NodeTree, StateRegistry};
use cove_devtools::inspection::UIDiagnostics;
use diffuse_ai::tools::project_toolset::ProjectToolset;
use diffuse_ai::tools::tool_policy::ToolCallOrigin;
use diffuse_kernel::codable::new_uuid;
use serde_json::{Value, json};

use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::EditorApplication;

struct Project {
    root: PathBuf,
    app: Rc<EditorApplication>,
}

impl Project {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("diffuse-diagnostics-{}", new_uuid()));
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
fn headless_reports_availability_and_skills_without_inventing_ui_data() {
    let project = Project::new();
    let report = project.call("get_diagnostics", json!({})).expect("diagnostics");
    assert_eq!(report["ok"], json!(true));
    assert_eq!(report["uiAvailable"], json!(false));
    assert_eq!(report["frameSampleCount"], json!(0));

    let skills = project.call("list_skills", json!({})).expect("skills");
    assert_eq!(skills["data"][0]["name"], json!("ui-diagnostics"));

    let skill = project
        .call("read_skill", json!({"name": "ui-diagnostics"}))
        .expect("skill");
    assert!(
        skill["data"]["instructions"]
            .as_str()
            .is_some_and(|instructions| instructions.contains("get_diagnostics"))
    );

    let error = project
        .call("query_ui_nodes", json!({}))
        .expect_err("headless query");
    assert!(error.message.contains("UI diagnostics are unavailable"));
}

#[test]
fn shared_executor_uses_attached_facade_and_preserves_explicit_state_boundary() {
    let project = Project::new();
    let node = Node::new();
    node.set_view_tag(Some("Toolbar".to_string()));
    let mut tree = NodeTree::new();
    tree.set_root(Some(node));

    let reads = Rc::new(Cell::new(0usize));
    let mut registry = StateRegistry::new();
    let counter = reads.clone();
    let id = registry
        .register(None, "count", "Int", None, move || {
            counter.set(counter.get() + 1);
            "3".to_string()
        })
        .expect("state id");

    let diagnostics = UIDiagnostics::new(Rc::new(RefCell::new(tree)), Some(registry));
    project
        .app
        .set_ui_diagnostics(Some(Arc::new(diagnostics)));

    let nodes = project
        .call("query_ui_nodes", json!({"text": "Toolbar", "limit": 1}))
        .expect("ui nodes");
    assert_eq!(nodes["data"]["total"], json!(1));

    project
        .call("query_ui_state", json!({}))
        .expect("state list");
    assert_eq!(reads.get(), 0);
    project
        .call("query_ui_state", json!({"ids": [id]}))
        .expect("state values");
    assert_eq!(reads.get(), 1);

    let names = project
        .app
        .store
        .state()
        .content
        .profile()
        .project_tool_names();
    assert!(
        UITools::tools()
            .iter()
            .all(|tool| names.contains(&tool.name.to_string()))
    );
    assert!(
        ProjectToolset::tools()
            .iter()
            .any(|tool| tool.name == "capture_ui_trace" && tool.read_only)
    );

    project.app.set_ui_diagnostics(None);
    project
        .call("capture_ui_trace", json!({"duration_ms": 50}))
        .expect_err("detached trace");
}
