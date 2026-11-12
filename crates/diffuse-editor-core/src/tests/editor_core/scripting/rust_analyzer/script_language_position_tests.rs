//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/ScriptLanguagePositionTests.swift`.

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptSourceCoordinates,
};

fn buffer(text: &str) -> TextBuffer {
    TextBuffer::from(text)
}

/// Maps single-line offsets to UTF-16 characters.
#[test]
fn maps_single_line() {
    let text = buffer("let x = 1");
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 0),
        ScriptLanguagePosition::new(0, 0)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 4),
        ScriptLanguagePosition::new(0, 4)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, text.character_count()),
        ScriptLanguagePosition::new(0, text.character_count())
    );
}

/// Counts non-BMP characters as two UTF-16 units.
#[test]
fn counts_surrogate_pairs() {
    let text = buffer("ab😀cd");
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 2),
        ScriptLanguagePosition::new(0, 2)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 3),
        ScriptLanguagePosition::new(0, 4)
    );
}

/// Advances lines and keeps a caret at end of line on that line.
#[test]
fn tracks_lines() {
    let text = buffer("abc\ndef");
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 3),
        ScriptLanguagePosition::new(0, 3)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 4),
        ScriptLanguagePosition::new(1, 0)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 7),
        ScriptLanguagePosition::new(1, 3)
    );
}

/// Handles a trailing newline as its own final line.
#[test]
fn handles_trailing_newline() {
    let text = buffer("abc\n");
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 3),
        ScriptLanguagePosition::new(0, 3)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 4),
        ScriptLanguagePosition::new(1, 0)
    );
}

/// Clamps out-of-range indices instead of trapping.
#[test]
fn clamps_invalid_indices() {
    let text = buffer("abc");
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 0),
        ScriptLanguagePosition::new(0, 0)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&text, 99),
        ScriptLanguagePosition::new(0, 3)
    );
    assert_eq!(
        ScriptSourceCoordinates::position_at_character_index(&TextBuffer::empty(), 0),
        ScriptLanguagePosition::ZERO
    );
}

/// Round-trips through character index for CJK content.
#[test]
fn round_trips_cjk() {
    let text = buffer("变量 timer\n_ = 秒");
    for index in 0..=text.character_count() {
        let position = ScriptSourceCoordinates::position_at_character_index(&text, index);
        assert_eq!(
            ScriptSourceCoordinates::character_index(&text, position),
            index
        );
    }
}

/// Clamps a server reply that lands past the end of a line.
#[test]
fn clamps_oversized_server_position() {
    let text = buffer("abc\ndef");
    let index = ScriptSourceCoordinates::character_index(&text, ScriptLanguagePosition::new(0, 99));
    // End of line 0 — before the newline.
    assert_eq!(index, 3);
}

/// Extracts the enclosing identifier.
#[test]
fn extracts_identifier() {
    let text = buffer("context.deltaTime += 1");
    let range = ScriptSourceCoordinates::identifier_range(&text, 12).expect("identifier");
    assert_eq!(text.substring(range), "deltaTime");
}

/// Returns the identifier trailing the caret when on punctuation.
#[test]
fn handles_trailing_caret() {
    let text = buffer("context.delta");
    let range = ScriptSourceCoordinates::identifier_range(&text, text.character_count())
        .expect("trailing identifier");
    // "context." occupies indices 0..<8, so the trailing word is 8..<13.
    assert_eq!(range, 8..13);
}

/// Reports no identifier for whitespace or lone punctuation.
#[test]
fn reports_no_identifier() {
    let text = buffer("  ,  ");
    assert_eq!(ScriptSourceCoordinates::identifier_range(&text, 2), None);
}

/// Converts positions to UTF-8 offsets for highlighting.
#[test]
fn converts_to_utf8_offset() {
    // "é" is one UTF-16 unit but two UTF-8 bytes, so column 1 (the space)
    // maps to byte offset 2 and column 2 ("x") maps to 3.
    let text = buffer("é x");
    assert_eq!(
        ScriptSourceCoordinates::utf8_offset(&text, ScriptLanguagePosition::new(0, 1)),
        2
    );
    assert_eq!(
        ScriptSourceCoordinates::utf8_offset(&text, ScriptLanguagePosition::new(0, 2)),
        3
    );
}
