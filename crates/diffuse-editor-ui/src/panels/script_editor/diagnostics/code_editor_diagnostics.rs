//! Translation of
//! Editor/Sources/EditorUI/Panels/ScriptEditor/Diagnostics/CodeEditorDiagnostics.swift.
//!
//! Only rebuild the interval index when its source revision or reply changes.

use cove_ui_compose::primitives::overlays::TooltipAnchor;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use cove_ui_compose::primitives::text::text_diagnostic::{
    TextDiagnostic, TextDiagnosticSeverity, TextDiagnosticStyle, TextDiagnostics,
};
use diffuse_editor_core::scripting::rust_analyzer::language::script_language_models::{
    ScriptDiagnosticSeverity, ScriptDiagnosticTag, ScriptLanguageDiagnostic,
};
use diffuse_editor_core::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguagePosition, ScriptSourceCoordinates,
};

#[derive(Clone, Default)]
pub struct ScriptCodeEditorDiagnostics {
    buffer: Option<TextBuffer>,
    source: Vec<ScriptLanguageDiagnostic>,
    mapped: TextDiagnostics,
}

impl ScriptCodeEditorDiagnostics {
    pub fn new() -> Self {
        ScriptCodeEditorDiagnostics {
            buffer: None,
            source: Vec::new(),
            mapped: TextDiagnostics::empty(),
        }
    }

    pub fn mapped(&self) -> &TextDiagnostics {
        &self.mapped
    }

    pub fn synchronize(
        &mut self,
        buffer: &TextBuffer,
        diagnostics: &[ScriptLanguageDiagnostic],
    ) -> TextDiagnostics {
        if self.buffer.as_ref() == Some(buffer) && self.source == diagnostics {
            return self.mapped.clone();
        }
        self.buffer = Some(buffer.clone());
        self.source = diagnostics.to_vec();
        self.mapped = if diagnostics.is_empty() {
            TextDiagnostics::empty()
        } else {
            let mapped: Vec<TextDiagnostic> = diagnostics
                .iter()
                .map(|diagnostic| {
                    let start = ScriptSourceCoordinates::utf8_offset(
                        buffer,
                        ScriptLanguagePosition::new(
                            diagnostic.start_line,
                            diagnostic.start_character,
                        ),
                    );
                    let end = ScriptSourceCoordinates::utf8_offset(
                        buffer,
                        ScriptLanguagePosition::new(diagnostic.end_line, diagnostic.end_character),
                    );
                    let severity = match diagnostic.severity {
                        ScriptDiagnosticSeverity::Error => TextDiagnosticSeverity::Error,
                        ScriptDiagnosticSeverity::Warning => TextDiagnosticSeverity::Warning,
                        ScriptDiagnosticSeverity::Information => {
                            TextDiagnosticSeverity::Information
                        }
                        ScriptDiagnosticSeverity::Hint => TextDiagnosticSeverity::Hint,
                    };
                    let mut mapped = TextDiagnostic::new(
                        start..start.max(end),
                        severity,
                        diagnostic.message.clone(),
                    );
                    if diagnostic.tags.contains(&ScriptDiagnosticTag::Deprecated) {
                        mapped.style = TextDiagnosticStyle::StruckThrough;
                    } else if diagnostic.tags.contains(&ScriptDiagnosticTag::Unnecessary) {
                        mapped.style = TextDiagnosticStyle::Faded;
                    }
                    mapped
                })
                .collect();
            TextDiagnostics::new(&mapped)
        };
        self.mapped.clone()
    }
}

pub struct ScriptDiagnosticHover {
    pub buffer: TextBuffer,
    pub anchor: TooltipAnchor,
    pub message: String,
}

impl ScriptDiagnosticHover {
    pub fn new(buffer: TextBuffer, anchor: TooltipAnchor, message: impl Into<String>) -> Self {
        ScriptDiagnosticHover {
            buffer,
            anchor,
            message: message.into(),
        }
    }
}
