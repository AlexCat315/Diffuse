//! Incremental document synchronization, translated from the Swift suite.

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use serde_json::Value;

use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptSourceCoordinates,
};
use crate::scripting::rust_analyzer::language::script_language_protocol::ScriptLanguageQueries;

fn replay(data: &[u8], old: &str) -> String {
    let object: Value = serde_json::from_slice(data).expect("valid change JSON");
    let changes = object["contentChanges"]
        .as_array()
        .expect("content changes");
    assert_eq!(changes.len(), 1);
    let change = &changes[0];
    let index = |point: &Value| {
        let line = point["line"].as_u64().expect("line") as usize;
        let column = point["character"].as_u64().expect("character") as usize;
        let start = old
            .split_inclusive('\n')
            .take(line)
            .map(str::len)
            .sum::<usize>();
        let mut units = 0;
        for (offset, character) in old[start..].char_indices() {
            if units == column {
                return start + offset;
            }
            assert_ne!(character, '\n', "position exceeds line");
            units += character.len_utf16();
            assert!(units <= column, "position splits a surrogate pair");
        }
        assert_eq!(units, column);
        old.len()
    };
    let start = index(&change["range"]["start"]);
    let end = index(&change["range"]["end"]);
    let mut result = old.to_owned();
    result.replace_range(
        start..end,
        change["text"].as_str().expect("replacement text"),
    );
    result
}

#[test]
fn unicode_wire_range() {
    let old = TextBuffer::from("é😀e\u{301} tail\r\nlet 中文 = 2\r\n");
    let next = old.replace(3..7, " replacement😀\n");
    let data = ScriptLanguageQueries::did_change("file:///test.rs", &old, &next, 2)
        .expect("serialize change")
        .expect("changed");
    assert_eq!(replay(&data, &old.string_value()), next.string_value());
    let object: Value = serde_json::from_slice(&data).expect("valid JSON");
    assert_eq!(
        object["contentChanges"][0]["range"]["start"]["character"],
        5
    );
    assert_eq!(
        ScriptSourceCoordinates::utf8_offset(&old, ScriptLanguagePosition::new(0, 4)),
        7
    );
}

#[test]
fn coalesced_and_undo() {
    let old = TextBuffer::from("let value = 1\n".repeat(100_000).as_str());
    let index = old.line_range(50_000).end;
    let mut next = old.clone();
    for _ in 0..40 {
        next = next.insert("x", index);
    }
    let change = |previous: &TextBuffer, current: &TextBuffer, version| {
        ScriptLanguageQueries::did_change("file:///test.rs", previous, current, version)
            .expect("serialize change")
    };
    let data = change(&old, &next, 2).expect("changed");
    assert!(data.len() < 500);
    assert_eq!(replay(&data, &old.string_value()), next.string_value());
    let undo = change(&next, &old, 3).expect("undo changed");
    assert_eq!(replay(&undo, &next.string_value()), old.string_value());
    assert!(change(&old, &old, 4).is_none());
    assert!(change(&old, &TextBuffer::from(old.string_value().as_str()), 4).is_none());
}
