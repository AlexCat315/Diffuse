//! `Editor/Sources/EditorCore/Scripting/Assets/LanguageEditHistory.swift`.

use std::ops::Range;

use cove_ui_compose::primitives::text::text_buffer::TextBuffer;

use crate::scripting::rust_analyzer::language::editing::ScriptLanguageEditError;
use crate::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptLanguageSpan, ScriptSourceCoordinates,
};

#[derive(Clone)]
pub struct ScriptLanguageEditHistory {
    pub undo: Vec<Vec<ScriptLanguageEditChange>>,
    pub redo: Vec<Vec<ScriptLanguageEditChange>>,
}

impl ScriptLanguageEditHistory {
    pub fn new() -> Self {
        Self {
            undo: Vec::new(),
            redo: Vec::new(),
        }
    }

    pub fn record(&mut self, changes: Vec<ScriptLanguageEditChange>) {
        if changes.is_empty() {
            return;
        }
        self.undo.push(changes);
        if self.undo.len() > 50 {
            self.undo.remove(0);
        }
        self.redo.clear();
    }
}

impl Default for ScriptLanguageEditHistory {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone)]
pub struct ScriptLanguageEditChange {
    pub script_id: String,
    pub before: TextBuffer,
    pub after: TextBuffer,
}

impl ScriptLanguageEditChange {
    pub fn new(script_id: String, before: TextBuffer, after: TextBuffer) -> Self {
        Self {
            script_id,
            before,
            after,
        }
    }
}

pub struct ScriptLanguageEditValidation;

impl ScriptLanguageEditValidation {
    pub fn range(
        span: ScriptLanguageSpan,
        source: &TextBuffer,
    ) -> Result<Range<usize>, ScriptLanguageEditError> {
        let lower = Self::index(span.start, source)?;
        let upper = Self::index(span.end, source)?;
        if lower > upper {
            return Err(ScriptLanguageEditError::InvalidRange);
        }
        Ok(lower..upper)
    }

    fn index(
        position: ScriptLanguagePosition,
        source: &TextBuffer,
    ) -> Result<usize, ScriptLanguageEditError> {
        if position.line >= source.line_count() {
            return Err(ScriptLanguageEditError::InvalidRange);
        }
        let index = ScriptSourceCoordinates::character_index(source, position);
        if ScriptSourceCoordinates::position_at_character_index(source, index) != position {
            return Err(ScriptLanguageEditError::InvalidRange);
        }
        Ok(index)
    }
}
