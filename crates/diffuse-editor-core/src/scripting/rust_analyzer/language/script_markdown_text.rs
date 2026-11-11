//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/ScriptMarkdownText.swift`.
//!
//! Turns SourceKit-LSP hover markup into renderable plain text.
//!
//! Documentation arrives as Markdown with a fenced Swift declaration followed
//! by prose. The popup draws with a single fixed-width font, so inline styling
//! has to be reduced to something legible while keeping the declaration the
//! most prominent part.

use std::collections::BTreeSet;

pub struct ScriptMarkdownText;

/// Doc-comment section headings that add nothing once the declaration and
/// prose are already separated visually.
const DROPPED_HEADINGS: [&str; 13] = [
    "declaration",
    "summary",
    "overview",
    "discussion",
    "parameters",
    "parameter",
    "returns",
    "return",
    "throws",
    "note",
    "precondition",
    "important",
    "see also",
];

impl ScriptMarkdownText {
    /// Reduces markup to `declaration\n\nprose`, dropping fenced block markers
    /// and inline styling. Whitespace-only input yields an empty string.
    pub fn plain_summary(markdown: &str) -> String {
        let dropped: BTreeSet<&str> = DROPPED_HEADINGS.into_iter().collect();
        let mut declaration: Vec<String> = Vec::new();
        let mut prose: Vec<String> = Vec::new();
        let mut is_inside_code_block = false;

        for raw_line in markdown.split('\n') {
            let trimmed = trim_horizontal(raw_line);
            if trimmed.starts_with("```") {
                is_inside_code_block = !is_inside_code_block;
                continue;
            }
            if trimmed.is_empty() {
                continue;
            }
            if is_inside_code_block {
                declaration.push(trimmed.to_string());
            } else {
                let cleaned = strip_inline_markup(trimmed);
                if cleaned.is_empty() {
                    continue;
                }
                if dropped.contains(cleaned.to_lowercase().as_str()) {
                    continue;
                }
                prose.push(cleaned);
            }
        }

        let mut sections: Vec<String> = Vec::new();
        if !declaration.is_empty() {
            sections.push(declaration.join(" "));
        }
        let summary = collapse_sentences(&prose);
        if !summary.is_empty() {
            sections.push(summary);
        }
        sections.join("\n\n")
    }
}

/// Collapses Soft-wrapped prose into single paragraphs while preserving
/// Markdown list structure, which doc comments rely on for parameters.
fn collapse_sentences(lines: &[String]) -> String {
    let mut paragraphs: Vec<String> = Vec::new();
    let mut current: Vec<String> = Vec::new();

    fn flush(paragraphs: &mut Vec<String>, current: &mut Vec<String>) {
        if current.is_empty() {
            return;
        }
        paragraphs.push(current.join(" "));
        current.clear();
    }

    for line in lines {
        let is_bullet = line.starts_with("• ") || line.starts_with("- ") || line.starts_with("* ");
        if is_bullet {
            flush(&mut paragraphs, &mut current);
            let body = trim_horizontal(&line[2..]);
            if !body.is_empty() {
                paragraphs.push(format!("• {body}"));
            }
        } else {
            current.push(line.clone());
        }
    }
    flush(&mut paragraphs, &mut current);
    paragraphs.join("\n")
}

fn strip_inline_markup(line: &str) -> String {
    let mut result = line.to_string();
    // Section headings (### Declaration) carry no information once the
    // declaration itself is hoisted above the prose.
    while result.starts_with('#') {
        result.remove(0);
    }
    result = trim_horizontal(&result).to_string();
    for token in ["**", "__", "`", "*", "_"] {
        result = result.replace(token, "");
    }
    result = replace_links(&result);
    trim_horizontal(&result).to_string()
}

/// `[label](target)` → `label`, scanning left to right like the Swift regular
/// expression (a target may itself contain `(`).
fn replace_links(line: &str) -> String {
    let characters: Vec<char> = line.chars().collect();
    let mut result = String::with_capacity(line.len());
    let mut index = 0;
    while index < characters.len() {
        if characters[index] != '[' {
            result.push(characters[index]);
            index += 1;
            continue;
        }
        let Some(close) = find_from(&characters, index + 1, |character| {
            character == ']' || character == '['
        }) else {
            result.push(characters[index]);
            index += 1;
            continue;
        };
        if characters[close] != ']' || close + 1 >= characters.len() || characters[close + 1] != '('
        {
            result.push(characters[index]);
            index += 1;
            continue;
        }
        let Some(end) = find_from(&characters, close + 2, |character| character == ')') else {
            result.push(characters[index]);
            index += 1;
            continue;
        };
        result.extend(&characters[index + 1..close]);
        index = end + 1;
    }
    result
}

fn find_from(characters: &[char], start: usize, predicate: impl Fn(char) -> bool) -> Option<usize> {
    (start..characters.len()).find(|index| predicate(characters[*index]))
}

/// `trimmingCharacters(in: .whitespaces)`: horizontal whitespace only.
fn trim_horizontal(value: &str) -> &str {
    value.trim_matches(|character: char| character == ' ' || character == '\t')
}
