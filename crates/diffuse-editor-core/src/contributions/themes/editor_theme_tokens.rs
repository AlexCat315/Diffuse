//! `Editor/Sources/EditorCore/Contributions/Themes/EditorThemeTokens.swift`.

use std::collections::BTreeMap;

use cove_ui_compose::scene_core::Color;
use cove_ui_compose::theme::{SemanticColorRef, ThemeExtension};

/// Design tokens the editor adds to the SDK's closed set of roles.
///
/// Swift declared this as a `ThemeExtension` value type with `internal(set)`
/// properties; the Rust `ThemeExtensions` store replaces the whole value on
/// `set`, so the fields are public and consumers mutate a copy.
#[derive(Clone, Debug, PartialEq)]
pub struct EditorThemeTokens {
    pub assistant: Color,
    pub syntax: BTreeMap<String, Color>,
}

impl EditorThemeTokens {
    pub fn new() -> Self {
        EditorThemeTokens {
            assistant: Color::from_rgba8(0xF0, 0x7D, 0x96, 0xFF),
            syntax: BTreeMap::new(),
        }
    }

    /// Late-bound assistant accent. Swift's `static let assistantColor` had a
    /// stable identity; the reference is only resolved against a theme, so a
    /// fresh ref per call resolves identically.
    pub fn assistant_color() -> SemanticColorRef {
        SemanticColorRef::new(|theme| theme.extensions.get::<EditorThemeTokens>().assistant)
    }
}

impl Default for EditorThemeTokens {
    fn default() -> Self {
        Self::new()
    }
}

impl ThemeExtension for EditorThemeTokens {
    fn default_value() -> Self {
        Self::new()
    }
}
