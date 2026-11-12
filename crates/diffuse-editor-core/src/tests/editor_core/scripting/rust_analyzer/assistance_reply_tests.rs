//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/AssistanceReplyTests.swift`.

use std::collections::BTreeSet;
use std::path::PathBuf;

use serde_json::json;

use crate::scripting::rust_analyzer::language::assistance_replies::ScriptAssistanceReplies;
use crate::scripting::rust_analyzer::language::script_language_models::ScriptDiagnosticTag;
use crate::scripting::rust_analyzer::language::script_language_protocol::ScriptLanguageReplies;
use crate::scripting::rust_analyzer::language::watched_files::ScriptWatchedFiles;

/// Diagnostics keep tags and related locations.
#[test]
fn diagnostics_keep_tags_and_relations() {
    let object = json!({
        "range": {"start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 10}},
        "message": "never used", "severity": 4, "tags": [1, 2, 9],
        "relatedInformation": [{
            "message": "declared here",
            "location": {
                "uri": "file:///p/A.swift",
                "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}},
            },
        }],
    });
    let diagnostic = ScriptLanguageReplies::parse_diagnostic(&object).expect("diagnostic");
    assert_eq!(
        diagnostic.tags,
        vec![
            ScriptDiagnosticTag::Unnecessary,
            ScriptDiagnosticTag::Deprecated
        ]
    );
    assert_eq!(diagnostic.related.len(), 1);
    assert_eq!(diagnostic.related[0].message, "declared here");
    assert_eq!(
        diagnostic.related[0].location.document_uri,
        "file:///p/A.swift"
    );
}

/// Completion items with data keep their resolution, documented ones do not.
#[test]
fn completion_resolution() {
    let pending =
        ScriptLanguageReplies::parse_completion_item(&json!({"label": "a", "data": {"id": 1}}))
            .expect("pending");
    let documented = ScriptLanguageReplies::parse_completion_item(
        &json!({"label": "b", "data": {"id": 2}, "documentation": "Docs"}),
    )
    .expect("documented");
    assert!(pending.resolution.is_some());
    assert!(documented.resolution.is_none());
    assert_eq!(documented.documentation.as_deref(), Some("Docs"));
}

/// Workspace symbols accept SymbolInformation and file-only WorkspaceSymbol.
#[test]
fn workspace_symbols() {
    let payload = serde_json::to_vec(&json!([
        {
            "name": "Point", "kind": 23, "containerName": "Board",
            "location": {
                "uri": "file:///p/Point.swift",
                "range": {"start": {"line": 3, "character": 7}, "end": {"line": 3, "character": 12}},
            },
        },
        {"name": "demo", "kind": 12, "location": {"uri": "file:///p/Demo.swift"}},
        {"name": "broken"},
    ]))
    .expect("payload");
    let symbols = ScriptAssistanceReplies::workspace_symbols(Some(&payload), 10);
    assert_eq!(
        symbols
            .iter()
            .map(|symbol| symbol.0.as_str())
            .collect::<Vec<_>>(),
        ["Point", "demo"]
    );
    assert_eq!(symbols[0].2.as_deref(), Some("Board"));
    assert_eq!(symbols[0].4.start.line, 3);
    assert_eq!(symbols[1].4.start.line, 0);
}

/// Watched files report creations, changes and deletions.
#[test]
fn watched_files() {
    let root = std::env::temp_dir().join(diffuse_kernel::codable::new_uuid());
    std::fs::create_dir_all(root.join("Sources/node_modules")).expect("directories");
    let kept = root.join("Sources/Kept.swift");
    let removed = root.join("Removed.swift");
    std::fs::write(&kept, "a").expect("kept");
    std::fs::write(&removed, "b").expect("removed");
    std::fs::write(root.join("Sources/node_modules/Ignored.swift"), "c").expect("ignored");
    std::fs::write(root.join("notes.txt"), "d").expect("notes");

    let extensions = BTreeSet::from(["swift".to_string()]);
    let names = BTreeSet::from(["Package.resolved".to_string()]);
    let before = ScriptWatchedFiles::scan(&root, &extensions, &names);

    let file = std::fs::OpenOptions::new()
        .write(true)
        .open(&kept)
        .expect("open kept");
    file.set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(60))
        .expect("touch kept");
    std::fs::remove_file(&removed).expect("remove");
    let added = root.join("Package.resolved");
    std::fs::write(&added, "{}").expect("package resolved");

    let changes = before.changes(&ScriptWatchedFiles::scan(&root, &extensions, &names));
    let described = changes
        .into_iter()
        .map(|change| {
            format!(
                "{}:{}",
                change
                    .url
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                change.change_type.raw_value()
            )
        })
        .collect::<BTreeSet<_>>();
    assert_eq!(
        described,
        BTreeSet::from([
            "Kept.swift:2".to_string(),
            "Removed.swift:3".to_string(),
            "Package.resolved:1".to_string(),
        ])
    );
    std::fs::remove_dir_all(PathBuf::from(root)).ok();
}
