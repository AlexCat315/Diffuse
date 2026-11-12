//! Translation of Editor/Sources/EditorUI/Panels/Documents/Writing/Formatting.swift.
//!
//! Markdown formatting commands as pure edits on a buffer and selection, so
//! the toolbar, shortcuts and tests share one implementation.

use std::ops::Range;

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::primitives::media::ui_icon_catalog;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarkdownFormat {
    Bold,
    Italic,
    Strikethrough,
    Code,
    Link,
    Heading,
    BulletList,
    NumberedList,
    TaskList,
    Quote,
}

impl MarkdownFormat {
    pub const ALL: [MarkdownFormat; 10] = [
        MarkdownFormat::Bold,
        MarkdownFormat::Italic,
        MarkdownFormat::Strikethrough,
        MarkdownFormat::Code,
        MarkdownFormat::Link,
        MarkdownFormat::Heading,
        MarkdownFormat::BulletList,
        MarkdownFormat::NumberedList,
        MarkdownFormat::TaskList,
        MarkdownFormat::Quote,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            MarkdownFormat::Bold => "bold",
            MarkdownFormat::Italic => "italic",
            MarkdownFormat::Strikethrough => "strikethrough",
            MarkdownFormat::Code => "code",
            MarkdownFormat::Link => "link",
            MarkdownFormat::Heading => "heading",
            MarkdownFormat::BulletList => "bulletList",
            MarkdownFormat::NumberedList => "numberedList",
            MarkdownFormat::TaskList => "taskList",
            MarkdownFormat::Quote => "quote",
        }
    }

    pub const fn title(self) -> &'static str {
        match self {
            MarkdownFormat::Bold => "Bold",
            MarkdownFormat::Italic => "Italic",
            MarkdownFormat::Strikethrough => "Strikethrough",
            MarkdownFormat::Code => "Inline Code",
            MarkdownFormat::Link => "Link",
            MarkdownFormat::Heading => "Heading",
            MarkdownFormat::BulletList => "Bulleted List",
            MarkdownFormat::NumberedList => "Numbered List",
            MarkdownFormat::TaskList => "Task List",
            MarkdownFormat::Quote => "Quote",
        }
    }

    pub fn icon(self) -> BundleImageResource {
        match self {
            MarkdownFormat::Bold => ui_icon_catalog::text::bold(),
            MarkdownFormat::Italic => ui_icon_catalog::text::italic(),
            MarkdownFormat::Strikethrough => ui_icon_catalog::action::minus(),
            MarkdownFormat::Code => ui_icon_catalog::editor::code(),
            MarkdownFormat::Link => ui_icon_catalog::action::link(),
            MarkdownFormat::Heading => ui_icon_catalog::text::heading(),
            MarkdownFormat::BulletList => ui_icon_catalog::text::list(),
            MarkdownFormat::NumberedList => ui_icon_catalog::text::list_ordered(),
            MarkdownFormat::TaskList => ui_icon_catalog::shape::square_check(),
            MarkdownFormat::Quote => ui_icon_catalog::text::pilcrow(),
        }
    }

    /// The letter used with the primary modifier, when the command has one.
    pub fn shortcut_letter(self) -> Option<char> {
        match self {
            MarkdownFormat::Bold => Some('b'),
            MarkdownFormat::Italic => Some('i'),
            MarkdownFormat::Link => Some('k'),
            MarkdownFormat::Strikethrough
            | MarkdownFormat::Code
            | MarkdownFormat::Heading
            | MarkdownFormat::BulletList
            | MarkdownFormat::NumberedList
            | MarkdownFormat::TaskList
            | MarkdownFormat::Quote => None,
        }
    }

    /// The edit for this command at `selection` (an empty range is the caret).
    pub fn edit(self, buffer: &TextBuffer, selection: Range<usize>) -> Edit {
        match self {
            MarkdownFormat::Bold => wrap(buffer, selection, "**", "**", "bold text"),
            MarkdownFormat::Italic => wrap(buffer, selection, "_", "_", "italic text"),
            MarkdownFormat::Strikethrough => wrap(buffer, selection, "~~", "~~", "text"),
            MarkdownFormat::Code => wrap(buffer, selection, "`", "`", "code"),
            MarkdownFormat::Link => {
                let text = buffer.substring(selection.clone());
                let label = if text.is_empty() { "link" } else { &text };
                let replacement = format!("[{label}](https://)");
                // Leave the caret inside the parentheses, ready for the address.
                Edit {
                    range: selection.clone(),
                    caret: selection.start + character_count(&replacement) - 1,
                    replacement,
                }
            }
            MarkdownFormat::Heading => prefix_lines(buffer, selection, |line, _| {
                // # → ## → ### → plain, the way writing apps cycle heading levels.
                let level = line
                    .chars()
                    .take_while(|character| *character == '#')
                    .count();
                let body = if level > 0 {
                    line[level..].trim_start_matches(' ')
                } else {
                    line
                };
                if level == 0 {
                    format!("# {body}")
                } else if level < 3 {
                    format!("{} {body}", "#".repeat(level + 1))
                } else {
                    body.to_owned()
                }
            }),
            MarkdownFormat::BulletList => toggle_prefix(buffer, selection, "- "),
            MarkdownFormat::TaskList => toggle_prefix(buffer, selection, "- [ ] "),
            MarkdownFormat::Quote => toggle_prefix(buffer, selection, "> "),
            MarkdownFormat::NumberedList => prefix_lines(buffer, selection, |line, index| {
                if let Some(rest) = strip_numbered_marker(line) {
                    return rest.to_owned();
                }
                format!("{}. {line}", index + 1)
            }),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    pub range: Range<usize>,
    pub replacement: String,
    /// Where the caret goes afterwards, in the edited buffer.
    pub caret: usize,
}

fn wrap(
    buffer: &TextBuffer,
    selection: Range<usize>,
    open: &str,
    close: &str,
    placeholder: &str,
) -> Edit {
    let text = buffer.substring(selection.clone());
    // Already wrapped: unwrap.
    if character_count(&text) >= character_count(open) + character_count(close)
        && text.starts_with(open)
        && text.ends_with(close)
    {
        let inner = &text[open.len()..text.len() - close.len()];
        let inner = inner.to_owned();
        return Edit {
            range: selection.clone(),
            caret: selection.start + character_count(&inner),
            replacement: inner,
        };
    }
    let before = if selection.start >= open.len() {
        buffer.substring((selection.start - open.len())..selection.start)
    } else {
        String::new()
    };
    let after = buffer.substring(
        selection.end..(buffer.character_count()).min(selection.end.saturating_add(close.len())),
    );
    if !text.is_empty() && before == open && after == close {
        let range = (selection.start - open.len())..(selection.end + close.len());
        return Edit {
            range: range.clone(),
            caret: range.start + character_count(&text),
            replacement: text,
        };
    }
    let body = if text.is_empty() { placeholder } else { &text };
    let replacement = format!("{open}{body}{close}");
    Edit {
        range: selection.clone(),
        caret: selection.start + open.len() + character_count(body),
        replacement,
    }
}

fn toggle_prefix(buffer: &TextBuffer, selection: Range<usize>, prefix: &str) -> Edit {
    let lines = line_span(buffer, selection.clone());
    let all = split_lines(&lines.text);
    let filled = all.iter().filter(|line| !line.is_empty()).count();
    let remove = filled > 0 && all.iter().all(|line| line.starts_with(prefix));
    prefix_lines(buffer, selection, |line, _| {
        if remove {
            return line.strip_prefix(prefix).unwrap_or(line).to_owned();
        }
        if line.is_empty() && all.len() > 1 {
            return line.to_owned();
        }
        format!("{prefix}{line}")
    })
}

fn prefix_lines(
    buffer: &TextBuffer,
    selection: Range<usize>,
    transform: impl Fn(&str, usize) -> String,
) -> Edit {
    let span = line_span(buffer, selection);
    let separator = if span.text.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let replacement = split_lines(&span.text)
        .iter()
        .enumerate()
        .map(|(index, line)| transform(line, index))
        .collect::<Vec<String>>()
        .join(separator);
    Edit {
        range: span.range.clone(),
        caret: span.range.start + character_count(&replacement),
        replacement,
    }
}

/// Whole lines touched by the selection.
fn line_span(buffer: &TextBuffer, selection: Range<usize>) -> LineSpan {
    let first = buffer.line_index_for_character_index(selection.start);
    let last_index = if selection.is_empty() {
        selection.start
    } else {
        selection.end - 1
    };
    let last = buffer.line_index_for_character_index(selection.start.max(last_index));
    let range = buffer.line_range(first).start..buffer.line_range(last).end;
    let text = buffer.substring(range.clone());
    LineSpan { range, text }
}

struct LineSpan {
    range: Range<usize>,
    text: String,
}

fn strip_numbered_marker(line: &str) -> Option<&str> {
    let digits = line
        .char_indices()
        .take_while(|(_, character)| character.is_ascii_digit())
        .count();
    if digits == 0 {
        return None;
    }
    line[digits..].strip_prefix(". ")
}

/// Swift's `split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)`.
fn split_lines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        if !is_newline(character) {
            continue;
        }
        lines.push(&text[start..index]);
        let mut end = index + character.len_utf8();
        if character == '\r'
            && let Some((next_index, '\n')) = characters.peek().copied()
        {
            characters.next();
            end = next_index + 1;
        }
        start = end;
    }
    lines.push(&text[start..]);
    lines
}

fn is_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\r' | '\u{000B}' | '\u{000C}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
    )
}

/// Grapheme-cluster count, matching Swift's `String.count`.
fn character_count(text: &str) -> usize {
    TextBuffer::new(text).character_count()
}
