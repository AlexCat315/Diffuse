//! `Editor/Tests/ScriptSystemTests/LanguageWorkspaceEditTests.swift`.
//!
//! Multi-file language edits stay one reversible buffer transaction, refuse
//! stale or overlapping ranges atomically, and never write on their own.
//!
//! Difference from Swift: `DynamicScriptManager(projectDirectory:scriptRuntime:
//! engineModulePaths:scriptTrustStorageURL:)` is `with_options` (the Rust
//! toolchain has no Swift toolchain to name), and `ScriptRuntime` is the
//! `diffuse_script` runtime taken by value rather than a `ScriptRuntime()`.

use std::path::PathBuf;
use std::sync::Arc;

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_script::ScriptRuntime;

use crate::scripting::assets::language_edit_history::ScriptLanguageEditValidation;
use crate::scripting::assets::script_workspace_model::{
    ScriptWorkspaceDocument, ScriptWorkspaceModel,
};
use crate::scripting::dynamic::dynamic_script_manager::DynamicScriptManager;
use crate::scripting::rust_analyzer::language::editing::{
    ScriptDocumentEdit, ScriptLanguageEditError, ScriptWorkspaceEdit,
};
use crate::scripting::rust_analyzer::language::script_language_models::ScriptCompletionTextEdit;
use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptLanguageSpan,
};

fn temporary_root(label: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "cove-workspace-edit-{}-{label}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&directory).expect("create temporary root");
    directory
}

/// Every case runs on the same two script documents; the workspace is shut down
/// on the way out.
fn with_workspace(label: &str, body: impl FnOnce(&ScriptWorkspaceModel, &Arc<DynamicScriptManager>)) {
    let root = temporary_root(label);
    let manager = Arc::new(DynamicScriptManager::with_options(
        &root.to_string_lossy(),
        ScriptRuntime::new(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Some(root.join("trust.json")),
        None,
    ));
    manager
        .create_script("First", "let value = 1\n")
        .expect("create First");
    manager
        .create_script("Second", "let value = 2\n")
        .expect("create Second");
    let model = ScriptWorkspaceModel::new(manager.clone()).expect("open workspace");

    body(&model, &manager);

    model.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

fn replacement(document: &ScriptWorkspaceDocument, revision: Option<u64>) -> ScriptDocumentEdit {
    ScriptDocumentEdit::new(
        document.file.identifier.clone(),
        revision.unwrap_or(document.edit_revision),
        vec![ScriptCompletionTextEdit::new(
            ScriptLanguageSpan::new(
                ScriptLanguagePosition {
                    line: 0,
                    character: 4,
                },
                ScriptLanguagePosition {
                    line: 0,
                    character: 9,
                },
            ),
            "renamed".to_string(),
        )],
    )
}

fn source_of(model: &ScriptWorkspaceModel, path: &std::path::Path) -> String {
    std::fs::read_to_string(path).expect("read source")
}

#[test]
fn grouped_undo_redo() {
    with_workspace("grouped", |model, manager| {
        let original = model.snapshot().documents;
        let edit = ScriptWorkspaceEdit::new(
            original
                .iter()
                .map(|document| replacement(document, None))
                .collect(),
        );
        model
            .apply_language_edit(&edit)
            .expect("apply the grouped edit");
        assert!(
            model
                .snapshot()
                .documents
                .iter()
                .all(|document| document.source.string_value().contains("renamed")
                    && document.is_dirty)
        );
        assert!(model.can_undo_language_edit());
        for document in &original {
            assert_eq!(source_of(model, &document.file.url), document.source.string_value());
            assert_eq!(
                manager.read_source(&document.file.url).expect("read script"),
                document.source.string_value()
            );
        }
        model.undo_language_edit().expect("undo the grouped edit");
        assert_eq!(
            model
                .snapshot()
                .documents
                .iter()
                .map(|document| document.source.string_value())
                .collect::<Vec<String>>(),
            original
                .iter()
                .map(|document| document.source.string_value())
                .collect::<Vec<String>>()
        );
        assert!(
            model
                .snapshot()
                .documents
                .iter()
                .all(|document| !document.is_dirty && document.edit_revision == 2)
        );
        assert!(model.can_redo_language_edit());
        model.redo_language_edit().expect("redo the grouped edit");
        assert!(
            model
                .snapshot()
                .documents
                .iter()
                .all(|document| document.source.string_value().contains("renamed")
                    && document.edit_revision == 3)
        );
    });
}

#[test]
fn stale_transaction() {
    with_workspace("stale", |model, _| {
        let original = model.snapshot().documents;
        let edit = ScriptWorkspaceEdit::new(vec![
            replacement(&original[0], None),
            replacement(&original[1], Some(1)),
        ]);
        assert!(matches!(
            model.apply_language_edit(&edit),
            Err(ScriptLanguageEditError::StaleDocument(_))
        ));
        assert_eq!(model.snapshot().documents, original);
        assert!(!model.can_undo_language_edit());
    });
}

#[test]
fn invalid_transaction() {
    with_workspace("invalid", |model, _| {
        let document = model.snapshot().selected_document().expect("selected document");
        let range = ScriptLanguageSpan::new(
            ScriptLanguagePosition {
                line: 0,
                character: 4,
            },
            ScriptLanguagePosition {
                line: 0,
                character: 9,
            },
        );
        let overlapping = ScriptDocumentEdit::new(
            document.file.identifier.clone(),
            0,
            vec![
                ScriptCompletionTextEdit::new(range, "a".to_string()),
                ScriptCompletionTextEdit::new(range, "b".to_string()),
            ],
        );
        assert_eq!(
            model.apply_language_edit(&ScriptWorkspaceEdit::new(vec![overlapping])),
            Err(ScriptLanguageEditError::OverlappingEdits)
        );
        let outside = ScriptDocumentEdit::new(
            document.file.identifier.clone(),
            0,
            vec![ScriptCompletionTextEdit::new(
                ScriptLanguageSpan::new(
                    ScriptLanguagePosition {
                        line: 99,
                        character: 0,
                    },
                    ScriptLanguagePosition {
                        line: 99,
                        character: 1,
                    },
                ),
                "x".to_string(),
            )],
        );
        assert_eq!(
            model.apply_language_edit(&ScriptWorkspaceEdit::new(vec![outside])),
            Err(ScriptLanguageEditError::InvalidRange)
        );
        assert_eq!(model.snapshot().selected_document(), Some(document));
    });
}

#[test]
fn preserves_subsequent_typing() {
    with_workspace("typing", |model, _| {
        let document = model.snapshot().selected_document().expect("selected document");
        model
            .apply_language_edit(&ScriptWorkspaceEdit::new(vec![replacement(&document, None)]))
            .expect("apply rename");
        let renamed = model
            .snapshot()
            .selected_document()
            .expect("selected document")
            .source;

        // Typing after the refactor breaks the grouped history: the undo cannot
        // overwrite what the user wrote since.
        model.update_selected_source(renamed.insert("// typing\n", 0));
        let typed = model.snapshot().selected_document().expect("selected document").source;
        assert!(!model.can_undo_language_edit());
        assert!(model.undo_language_edit().is_err());
        assert!(model
            .snapshot()
            .selected_document()
            .expect("selected document")
            .source
            .has_same_contents(&typed));

        model.update_selected_source(renamed.clone());
        assert!(model.can_undo_language_edit());
        model.undo_language_edit().expect("undo rename");
        assert!(model
            .snapshot()
            .selected_document()
            .expect("selected document")
            .source
            .has_same_contents(&document.source));
    });
}

#[test]
fn rejects_split_emoji() {
    let source = TextBuffer::new("😀a\n");
    let span = |start: usize, end: usize| {
        ScriptLanguageSpan::new(
            ScriptLanguagePosition {
                line: 0,
                character: start,
            },
            ScriptLanguagePosition {
                line: 0,
                character: end,
            },
        )
    };
    assert_eq!(
        ScriptLanguageEditValidation::range(span(1, 2), &source),
        Err(ScriptLanguageEditError::InvalidRange)
    );
    assert!(ScriptLanguageEditValidation::range(span(2, 3), &source).is_ok());
}
