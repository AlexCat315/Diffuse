//! `Editor/Tests/EditorCoreTests/WorkstationTests.swift`.
//!
//! Content profiles, the unsaved-buffer guard on document tools, and the tab
//! rules that keep project scripts owned by the script workspace.
//!
//! Difference from Swift: project scripts are `.rs` files created for the Rust
//! toolchain, so the generated-name assertions expect `NewScript.rs` and
//! `NewScript2.rs` instead of the `.swift` names the Swift build produced.

use std::path::PathBuf;
use std::rc::Rc;

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_ai::tools::tool_policy::ToolCallOrigin;

use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};
use crate::state::editor_reducer::EditorAction;
use crate::state::workspace::content::EditorContent;

fn temporary_project(label: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "studio-{label}-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&directory).expect("create temporary project");
    directory
}

fn launch(project: &PathBuf) -> Rc<EditorApplication> {
    EditorApplication::with_options(
        project.to_string_lossy().into_owned(),
        EditorApplicationOptions {
            seed_preview_scene: false,
            ..EditorApplicationOptions::default()
        },
    )
    .expect("launch editor")
}

#[test]
fn files_and_timeline_own_independent_workflow_tools() {
    let files = EditorContent::Files.profile();
    assert!(files.capability_ids().is_empty());
    assert!(files.project_tool_names().contains("write_file"));

    let timeline = EditorContent::Timeline.profile();
    assert!(timeline.capability_ids().is_empty());
    assert!(timeline.project_tool_names().contains("export_media"));
}

#[test]
fn ordinary_document_tools_protect_unsaved_buffers() {
    let root = temporary_project("docs");
    let application = launch(&root);
    let app: &EditorApplication = &application;
    app
        .store
        .dispatch(EditorAction::SetContent(EditorContent::Files));
    let created = application
        .execute_project_tool(
            "write_file",
            br#"{"path":"Notes.md","text":"First"}"#,
            ToolCallOrigin::Mcp,
        )
        .expect("first write");
    assert!(!created.is_empty());

    let documents = &application.workstation.documents;
    documents.open("Notes.md");
    documents.edit("Notes.md", "Unsaved");
    assert!(app.workstation.has_unsaved_changes());

    // The tool refuses to overwrite a buffer with edits the user has not saved.
    let refused = app.execute_project_tool(
        "write_file",
        br#"{"path":"Notes.md","text":"Replacement","expected_text":"First"}"#,
        ToolCallOrigin::Mcp,
    );
    assert!(refused.is_err());
    assert_eq!(
        std::fs::read_to_string(root.join("Notes.md")).expect("read Notes.md"),
        "First"
    );

    assert!(app.workstation.save_all());
    assert_eq!(
        std::fs::read_to_string(root.join("Notes.md")).expect("read Notes.md"),
        "Unsaved"
    );

    application.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn script_tabs_edit_through_the_script_workspace() {
    let root = temporary_project("script-docs");
    let application = launch(&root);
    let app: &EditorApplication = &application;
    let workstation = &app.workstation;

    assert!(workstation.scripts.create_script("First", "let first = 1\n"));
    assert!(workstation.scripts.create_script("Second", "let second = 2\n"));
    let snapshot = workstation.scripts.snapshot();
    let first = snapshot
        .documents
        .iter()
        .find(|document| document.file.display_name == "First")
        .expect("First script");
    let first_id = first.file.identifier.clone();
    let first_url = first.file.url.clone();
    let path = workstation
        .document_path_for_script(&first_id)
        .expect("script tab path");
    assert_eq!(
        workstation.script_id_for_document(&path).as_deref(),
        Some(first_id.as_str())
    );
    assert_eq!(workstation.script_id_for_document("Notes.md"), None);

    // Opening the tab moves the language session to its script.
    workstation.documents.open(&path);
    assert_eq!(
        workstation.scripts.snapshot().selected_script_id.as_deref(),
        Some(first_id.as_str())
    );
    workstation
        .scripts
        .update_selected_source(TextBuffer::new("let first = 10\n"));
    let tab = workstation
        .documents
        .snapshot()
        .selected()
        .cloned()
        .expect("front tab");
    assert!(workstation.is_document_dirty(&tab));

    // Switching tabs keeps unsaved script edits unsaved, like any document.
    let second_id = workstation
        .scripts
        .snapshot()
        .documents
        .iter()
        .find(|document| document.file.display_name == "Second")
        .map(|document| document.file.identifier.clone())
        .expect("Second script");
    let second_path = workstation
        .document_path_for_script(&second_id)
        .expect("second tab path");
    workstation.documents.open(&second_path);
    assert_eq!(
        workstation
            .scripts
            .snapshot()
            .documents
            .iter()
            .find(|document| document.file.identifier == first_id)
            .map(|document| document.is_dirty),
        Some(true)
    );
    assert_eq!(
        std::fs::read_to_string(&first_url).expect("read first script"),
        "let first = 1\n"
    );

    // A plain close is refused; save writes; revert and a discarding close drop
    // edits.
    workstation.close_document(&path, false);
    assert!(workstation.documents.error().is_some());
    assert!(
        workstation
            .documents
            .documents()
            .iter()
            .any(|document| document.path == path)
    );
    assert!(workstation.save_document(&path));
    assert_eq!(
        std::fs::read_to_string(&first_url).expect("read saved script"),
        "let first = 10\n"
    );
    workstation.documents.open(&path);
    workstation
        .scripts
        .update_selected_source(TextBuffer::new("let first = 11\n"));
    workstation.revert_document(&path);
    let reverted = workstation
        .documents
        .snapshot()
        .selected()
        .cloned()
        .expect("front tab");
    assert!(!workstation.is_document_dirty(&reverted));
    workstation
        .scripts
        .update_selected_source(TextBuffer::new("let first = 12\n"));
    workstation.close_document(&path, true);
    assert!(
        !workstation
            .documents
            .documents()
            .iter()
            .any(|document| document.path == path)
    );
    assert_eq!(
        workstation
            .scripts
            .snapshot()
            .documents
            .iter()
            .find(|document| document.file.identifier == first_id)
            .map(|document| document.is_dirty),
        Some(false)
    );

    application.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn scripts_are_created_and_deleted_as_documents() {
    let root = temporary_project("script-lifecycle");
    let application = launch(&root);
    let app: &EditorApplication = &application;
    let workstation = &app.workstation;

    // New scripts take the next free name and open in front.
    let first = workstation
        .create_script("let a = 1\n")
        .expect("first script");
    let second = workstation
        .create_script("let b = 2\n")
        .expect("second script");
    assert!(first.ends_with("NewScript.rs"), "{first} {second}");
    assert!(second.ends_with("NewScript2.rs"), "{first} {second}");
    assert_eq!(workstation.documents.selected_path().as_deref(), Some(second.as_str()));
    assert_eq!(
        workstation.scripts.snapshot().selected_script_id,
        workstation.script_id_for_document(&second)
    );
    assert_eq!(
        workstation.document_path_for(&app.workstation.scripts.manager().scripts_directory_url()),
        Some("Scripts".to_string())
    );

    // Deleting removes file and tab, unsaved edits included, and the front tab
    // keeps its language session.
    workstation.documents.open(&first);
    workstation
        .scripts
        .update_selected_source(TextBuffer::new("let a = 10\n"));
    workstation.documents.open(&second);
    assert!(workstation.delete_script_at_document(&first));
    assert!(!root.join(&first).exists());
    assert!(
        !workstation
            .documents
            .documents()
            .iter()
            .any(|document| document.path == first)
    );
    assert_eq!(workstation.script_id_for_document(&first), None);
    assert_eq!(
        workstation.scripts.snapshot().selected_script_id,
        workstation.script_id_for_document(&second)
    );
    assert!(!workstation.delete_script_at_document("Notes.md"));

    application.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
