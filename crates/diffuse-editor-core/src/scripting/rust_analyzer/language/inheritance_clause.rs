//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/InheritanceClause.swift`.

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

use super::script_language_position::{ScriptLanguagePosition, ScriptSourceCoordinates};

/// Reads a type declaration's inheritance clause straight from source, for
/// when the server's index has no type hierarchy (types from binary modules).
pub(crate) struct ScriptInheritanceClause;

impl ScriptInheritanceClause {
    /// Positions of each inherited type's name in `struct Name<T>: A, B.C & D {`,
    /// given the position of `Name`. Qualified names point at their last part.
    pub fn type_positions(
        text: &TextBuffer,
        position: ScriptLanguagePosition,
    ) -> Vec<ScriptLanguagePosition> {
        let start = ScriptSourceCoordinates::character_index(text, position);
        let end = usize::min(text.character_count(), start.saturating_add(600));
        let window: Vec<char> = text.substring(start..end).chars().collect();
        let mut index = 0;

        fn skip_space(window: &[char], index: &mut usize) {
            while *index < window.len() && window[*index].is_whitespace() {
                *index += 1;
            }
        }

        fn is_name(character: char) -> bool {
            character == '_' || character.is_alphabetic() || character.is_numeric()
        }

        fn skip_generics(window: &[char], index: &mut usize) {
            if *index >= window.len() || window[*index] != '<' {
                return;
            }
            let mut depth: i64 = 0;
            while *index < window.len() {
                if window[*index] == '<' {
                    depth += 1;
                } else if window[*index] == '>' {
                    depth -= 1;
                }
                *index += 1;
                if depth == 0 {
                    return;
                }
            }
        }

        while index < window.len() && is_name(window[index]) {
            index += 1;
        }
        skip_space(&window, &mut index);
        skip_generics(&window, &mut index);
        skip_space(&window, &mut index);
        if index >= window.len() || window[index] != ':' {
            return Vec::new();
        }
        index += 1;

        let mut positions: Vec<ScriptLanguagePosition> = Vec::new();
        loop {
            skip_space(&window, &mut index);
            if index >= window.len() || !is_name(window[index]) {
                break;
            }
            let mut last = index;
            while index < window.len() && (is_name(window[index]) || window[index] == '.') {
                if window[index] == '.' {
                    last = index + 1;
                }
                index += 1;
            }
            positions.push(ScriptSourceCoordinates::position_at_character_index(
                text,
                start + last,
            ));
            skip_generics(&window, &mut index);
            skip_space(&window, &mut index);
            if index >= window.len() || !(window[index] == ',' || window[index] == '&') {
                break;
            }
            index += 1;
        }
        positions
    }
}
