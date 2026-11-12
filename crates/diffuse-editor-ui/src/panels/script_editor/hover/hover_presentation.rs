//! Translation of
//! Editor/Sources/EditorUI/Panels/ScriptEditor/Hover/HoverPresentation.swift.
//!
//! What the hover popup shows, split from how it is produced: the resolver
//! turns pointer pauses into requests, this file turns replies into blocks.

use diffuse_editor_core::scripting::rust_analyzer::language::script_language_models::{
    ScriptHoverResult, ScriptMarkupKind,
};

/// Window-space point the hover popup should hang from — normally just below
/// the glyph the pointer is resting on.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScriptEditorHoverAnchor {
    pub window_x: f32,
    pub window_y: f32,
}

impl ScriptEditorHoverAnchor {
    pub fn new(window_x: f32, window_y: f32) -> Self {
        ScriptEditorHoverAnchor { window_x, window_y }
    }
}

/// Popup body split into a signature and optional prose.
///
/// Splitting here keeps the drawing pass dumb: it lays out two blocks with
/// different font slots instead of parsing the server's markup again every
/// frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScriptEditorHoverContent {
    pub declaration: String,
    pub detail: Option<String>,
    /// The server's Markdown, rendered as is when it sent any.
    pub markdown: Option<String>,
}

impl ScriptEditorHoverContent {
    pub fn new(declaration: impl Into<String>, detail: Option<String>) -> Self {
        ScriptEditorHoverContent {
            declaration: declaration.into(),
            detail,
            markdown: None,
        }
    }

    /// Swift's `init(_ result: ScriptHoverResult)`.
    pub fn from_result(result: &ScriptHoverResult) -> Self {
        // ``ScriptMarkdownText`` already joined the declaration and prose with a
        // blank line, so splitting on it recovers the two parts.
        let blocks: Vec<&str> = result
            .plain_text
            .split("\n\n")
            .map(str::trim)
            .filter(|block| !block.is_empty())
            .collect();
        let declaration = blocks.first().copied().unwrap_or_default().to_string();
        let detail = (blocks.len() > 1).then(|| blocks[1..].join("\n"));
        let contents = result.contents.trim();
        let markdown = (result.kind == ScriptMarkupKind::Markdown && !contents.is_empty())
            .then(|| contents.to_string());
        ScriptEditorHoverContent {
            declaration,
            detail,
            markdown,
        }
    }
}

/// Everything the hover overlay needs to render, and nothing else.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScriptEditorHoverPresentation {
    pub anchor: Option<ScriptEditorHoverAnchor>,
    pub content: Option<ScriptEditorHoverContent>,
    /// True while a request is in flight, so the popup can show a placeholder
    /// instead of flickering empty and then filling in.
    pub is_pending: bool,
    /// Shown when the server had nothing to say — kept distinct from "no hover"
    /// so the popup can be dismissed rather than stuck loading.
    pub message: Option<String>,
}

impl ScriptEditorHoverPresentation {
    pub fn hidden() -> Self {
        ScriptEditorHoverPresentation::default()
    }

    pub fn is_visible(&self) -> bool {
        self.content.is_some() || self.message.is_some()
    }

    /// Blocks handed to the drawing pass, in order.
    ///
    /// A pending request deliberately yields nothing — showing an empty bubble
    /// for 300 ms reads as a glitch, whereas having the popup appear when the
    /// answer lands reads as responsive.
    pub fn text_blocks(&self) -> Vec<ScriptHoverTextBlock> {
        if let Some(content) = &self.content {
            let mut blocks = vec![ScriptHoverTextBlock {
                text: content.declaration.clone(),
                role: ScriptHoverTextRole::Signature,
            }];
            if let Some(detail) = &content.detail
                && !detail.is_empty()
            {
                blocks.push(ScriptHoverTextBlock {
                    text: detail.clone(),
                    role: ScriptHoverTextRole::Body,
                });
            }
            return blocks;
        }
        if let Some(message) = &self.message {
            return vec![ScriptHoverTextBlock {
                text: message.clone(),
                role: ScriptHoverTextRole::Body,
            }];
        }
        Vec::new()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptHoverTextBlock {
    pub text: String,
    pub role: ScriptHoverTextRole,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptHoverTextRole {
    /// Declaration line — fixed-width, primary foreground.
    Signature,
    /// Prose, status notes, and messages.
    Body,
}
