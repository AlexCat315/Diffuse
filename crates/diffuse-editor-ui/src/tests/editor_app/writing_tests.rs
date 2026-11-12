//! Ported from `Editor/Tests/EditorAppTests/WritingTests.swift`.

use std::ops::Range;

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

use crate::panels::documents::writing::formatting::MarkdownFormat;

fn apply(format: MarkdownFormat, text: &str, selection: Range<usize>) -> (String, usize) {
    let buffer = TextBuffer::new(text);
    let edit = format.edit(&buffer, selection);
    (
        buffer.replace(edit.range, &edit.replacement).string_value(),
        edit.caret,
    )
}

/// Inline formats wrap the selection, or remove the markers when the selection
/// already sits inside one.
#[test]
fn inline_formats_wrap_and_unwrap_the_selection() {
    assert_eq!(
        apply(MarkdownFormat::Bold, "make it bold", 8..12),
        ("make it **bold**".to_owned(), 14)
    );
    // Selecting the inner text of an already-bold span removes the markers.
    assert_eq!(
        apply(MarkdownFormat::Bold, "make it **bold**", 10..14).0,
        "make it bold"
    );
    assert_eq!(apply(MarkdownFormat::Bold, "**bold**", 0..8).0, "bold");
    assert_eq!(
        apply(MarkdownFormat::Italic, "", 0..0),
        ("_italic text_".to_owned(), 12)
    );
    assert_eq!(
        apply(MarkdownFormat::Link, "see docs", 4..8),
        ("see [docs](https://)".to_owned(), 19)
    );
}

/// Line formats toggle every line the selection touches, keeping the document's
/// newline style.
#[test]
fn line_formats_toggle_every_touched_line() {
    assert_eq!(
        apply(MarkdownFormat::BulletList, "one\ntwo", 0..7).0,
        "- one\n- two"
    );
    assert_eq!(
        apply(MarkdownFormat::BulletList, "- one\n- two", 0..11).0,
        "one\ntwo"
    );
    assert_eq!(apply(MarkdownFormat::BulletList, "", 0..0).0, "- ");
    assert_eq!(
        apply(MarkdownFormat::NumberedList, "a\nb\nc", 2..5).0,
        "a\n1. b\n2. c"
    );
    assert_eq!(
        apply(MarkdownFormat::Quote, "text\r\nmore", 0..10).0,
        "> text\r\n> more"
    );
    // Headings cycle # → ## → ### → plain text.
    assert_eq!(apply(MarkdownFormat::Heading, "Title", 2..2).0, "# Title");
    assert_eq!(
        apply(MarkdownFormat::Heading, "# Title", 2..2).0,
        "## Title"
    );
    assert_eq!(apply(MarkdownFormat::Heading, "### Title", 2..2).0, "Title");
}
