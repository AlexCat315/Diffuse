//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/ScriptLanguagePosition.swift`.
//!
//! A zero-based `line` / UTF-16 `character` offset — the coordinate space the
//! Language Server Protocol mandates.
//!
//! The editor's text field tracks offsets in `Character` (grapheme cluster)
//! units, LSP talks UTF-16 code units, and the script highlighter works in UTF-8
//! bytes. Mixing them silently shifts every column for non-BMP characters, so
//! all three conversions funnel through [`ScriptSourceCoordinates`].

use std::ops::Range;

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ScriptLanguagePosition {
    pub line: usize,
    /// Offset measured in UTF-16 code units from the start of the line.
    pub character: usize,
}

impl ScriptLanguagePosition {
    pub fn new(line: usize, character: usize) -> Self {
        ScriptLanguagePosition { line, character }
    }

    /// Swift's `static let zero`.
    pub const ZERO: ScriptLanguagePosition = ScriptLanguagePosition {
        line: 0,
        character: 0,
    };
}

/// A half-open `[start, end)` range in LSP coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ScriptLanguageSpan {
    pub start: ScriptLanguagePosition,
    pub end: ScriptLanguagePosition,
}

impl ScriptLanguageSpan {
    pub fn new(start: ScriptLanguagePosition, end: ScriptLanguagePosition) -> Self {
        ScriptLanguageSpan { start, end }
    }

    pub fn with_corners(
        start_line: usize,
        start_character: usize,
        end_line: usize,
        end_character: usize,
    ) -> Self {
        ScriptLanguageSpan {
            start: ScriptLanguagePosition::new(start_line, start_character),
            end: ScriptLanguagePosition::new(end_line, end_character),
        }
    }
}

/// Conversions between editor indices and LSP positions.
///
/// Every member is a pure function over [`TextBuffer`], which keeps the subtle
/// UTF-16 arithmetic testable without a running language server.
pub struct ScriptSourceCoordinates;

impl ScriptSourceCoordinates {
    pub fn position_at_character_index(
        buffer: &TextBuffer,
        index: usize,
    ) -> ScriptLanguagePosition {
        Self::position_at_utf8_offset(buffer, buffer.utf8_offset_for_character_index(index))
    }

    pub fn position_at_utf8_offset(buffer: &TextBuffer, offset: usize) -> ScriptLanguagePosition {
        let point = buffer.point_for_utf8_offset(offset);
        let range = buffer.line_range(point.row);
        let byte = usize::min(buffer.utf8_offset_for_character_index(range.end), offset);
        let column = buffer.utf16_offset_for_utf8_offset(byte) as isize
            - buffer.utf16_offset_for_character_index(range.start) as isize;
        ScriptLanguagePosition {
            line: point.row,
            character: column.max(0) as usize,
        }
    }

    pub fn character_index(buffer: &TextBuffer, position: ScriptLanguagePosition) -> usize {
        buffer.character_index_for_utf8_offset(Self::utf8_offset(buffer, position))
    }

    pub fn utf8_offset(buffer: &TextBuffer, position: ScriptLanguagePosition) -> usize {
        let range = buffer.line_range(position.line);
        let start = buffer.utf16_offset_for_character_index(range.start);
        let end = buffer.utf16_offset_for_character_index(range.end);
        buffer.utf8_offset_for_utf16_offset(usize::min(end, start + position.character))
    }

    pub fn identifier_range(buffer: &TextBuffer, index: usize) -> Option<Range<usize>> {
        if buffer.is_empty() {
            return None;
        }
        let cursor = usize::min(buffer.character_count(), index);
        let mut lower = cursor;
        let mut upper = cursor;
        while lower > 0 {
            let Some(character) = buffer.character_at(lower - 1) else {
                break;
            };
            if !is_identifier(&character) {
                break;
            }
            lower -= 1;
        }
        if let Some(character) = buffer.character_at(cursor) {
            if is_identifier(&character) {
                while upper < buffer.character_count() {
                    let Some(character) = buffer.character_at(upper) else {
                        break;
                    };
                    if !is_identifier(&character) {
                        break;
                    }
                    upper += 1;
                }
            }
        }
        (lower < upper).then_some(lower..upper)
    }
}

fn is_identifier(character: &str) -> bool {
    let mut scalars = character.chars();
    let Some(scalar) = scalars.next() else {
        return false;
    };
    if scalar == '_' || scalar.is_alphabetic() || scalar.is_numeric() {
        return true;
    }
    if scalars.next().is_some() {
        return false;
    }
    scalar as u32 >= 0x80
}
