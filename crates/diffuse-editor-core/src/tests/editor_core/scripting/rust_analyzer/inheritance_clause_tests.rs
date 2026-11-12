//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/InheritanceClauseTests.swift`.

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

use crate::scripting::rust_analyzer::language::inheritance_clause::ScriptInheritanceClause;
use crate::scripting::rust_analyzer::language::script_language_position::ScriptLanguagePosition;

fn names(source: &str, line: usize, character: usize) -> Vec<String> {
    let text = TextBuffer::new(source);
    let lines: Vec<&str> = source.split('\n').collect();
    ScriptInheritanceClause::type_positions(&text, ScriptLanguagePosition::new(line, character))
        .into_iter()
        .map(|position| {
            lines[position.line]
                .chars()
                .skip(position.character)
                .take_while(|character| {
                    *character == '_' || character.is_alphabetic() || character.is_numeric()
                })
                .collect()
        })
        .collect()
}

/// Inherited names resolve to their last component, across generics,
/// compositions and lines.
#[test]
fn inherited_names_resolve_to_their_last_component() {
    assert_eq!(
        names("struct GameScript: ScriptBehavior, ScriptAuthoring {", 0, 7),
        vec!["ScriptBehavior", "ScriptAuthoring"]
    );
    assert_eq!(
        names(
            "final class Box<T: Equatable>: Base<T>, Runtime.Hashable & Sendable where T: Any {",
            0,
            12
        ),
        vec!["Base", "Hashable", "Sendable"]
    );
    assert_eq!(
        names("enum Mode:\n    String,\n    CaseIterable\n{", 0, 5),
        vec!["String", "CaseIterable"]
    );
    assert!(names("struct Plain {", 0, 7).is_empty());
    assert!(names("protocol Named { var name: String { get } }", 0, 9).is_empty());
}
