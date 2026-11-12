//! Translation of Editor/Sources/EditorUI/Panels/ScriptEditor/Syntax/Syntax.swift.
//!
//! Colours shared by every language the host highlights. Parsing lives in the
//! tree-sitter highlighter and the document grammar.

use std::collections::BTreeMap;

use cove_ui_compose::scene_core::Color;
use diffuse_plugin::contribution::languages::language::SyntaxToken;

/// Colours shared by every highlighted language.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyntaxCategory {
    Keyword,
    Type,
    Function,
    String,
    Number,
    Comment,
    Attribute,
    Directive,
}

impl SyntaxCategory {
    pub const fn raw_value(self) -> &'static str {
        match self {
            SyntaxCategory::Keyword => "keyword",
            SyntaxCategory::Type => "type",
            SyntaxCategory::Function => "function",
            SyntaxCategory::String => "string",
            SyntaxCategory::Number => "number",
            SyntaxCategory::Comment => "comment",
            SyntaxCategory::Attribute => "attribute",
            SyntaxCategory::Directive => "directive",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "keyword" => Some(SyntaxCategory::Keyword),
            "type" => Some(SyntaxCategory::Type),
            "function" => Some(SyntaxCategory::Function),
            "string" => Some(SyntaxCategory::String),
            "number" => Some(SyntaxCategory::Number),
            "comment" => Some(SyntaxCategory::Comment),
            "attribute" => Some(SyntaxCategory::Attribute),
            "directive" => Some(SyntaxCategory::Directive),
            _ => None,
        }
    }

    /// A plugin palette entry wins; otherwise the built-in light/dark swatches
    /// apply.
    pub fn color(self, light: bool, palette: &BTreeMap<String, Color>) -> Color {
        if let Some(color) = palette.get(self.raw_value()) {
            return *color;
        }
        if light {
            match self {
                SyntaxCategory::Keyword => Color::from_rgba8(0x7B, 0x35, 0xAE, 0xFF),
                SyntaxCategory::Type => Color::from_rgba8(0x00, 0x64, 0x83, 0xFF),
                SyntaxCategory::String => Color::from_rgba8(0x2E, 0x70, 0x3A, 0xFF),
                SyntaxCategory::Comment => Color::from_rgba8(0x67, 0x72, 0x82, 0xFF),
                SyntaxCategory::Number => Color::from_rgba8(0xA5, 0x49, 0x16, 0xFF),
                SyntaxCategory::Attribute | SyntaxCategory::Directive => {
                    Color::from_rgba8(0x88, 0x60, 0x15, 0xFF)
                }
                SyntaxCategory::Function => Color::from_rgba8(0x22, 0x57, 0xA0, 0xFF),
            }
        } else {
            match self {
                SyntaxCategory::Keyword => Color {
                    r: 0.78,
                    g: 0.62,
                    b: 0.96,
                    a: 1.0,
                },
                SyntaxCategory::Type => Color {
                    r: 0.43,
                    g: 0.78,
                    b: 0.92,
                    a: 1.0,
                },
                SyntaxCategory::String => Color {
                    r: 0.67,
                    g: 0.82,
                    b: 0.57,
                    a: 1.0,
                },
                SyntaxCategory::Comment => Color {
                    r: 0.48,
                    g: 0.54,
                    b: 0.58,
                    a: 1.0,
                },
                SyntaxCategory::Number => Color {
                    r: 0.95,
                    g: 0.70,
                    b: 0.43,
                    a: 1.0,
                },
                SyntaxCategory::Attribute | SyntaxCategory::Directive => Color {
                    r: 0.94,
                    g: 0.77,
                    b: 0.45,
                    a: 1.0,
                },
                SyntaxCategory::Function => Color {
                    r: 0.42,
                    g: 0.77,
                    b: 0.94,
                    a: 1.0,
                },
            }
        }
    }

    /// Swift extended `LanguageSyntaxRule.Token`; Rust cannot add an inherent
    /// impl to the plugin crate's enum, so the mapping is an associated function.
    pub fn for_token(token: SyntaxToken) -> Self {
        match token {
            SyntaxToken::Keyword => SyntaxCategory::Keyword,
            SyntaxToken::Type => SyntaxCategory::Type,
            SyntaxToken::Function => SyntaxCategory::Function,
            SyntaxToken::String => SyntaxCategory::String,
            SyntaxToken::Number => SyntaxCategory::Number,
            SyntaxToken::Comment => SyntaxCategory::Comment,
            // The plugin token set maps attributes and directives to one swatch.
            SyntaxToken::Attribute | SyntaxToken::Directive => SyntaxCategory::Attribute,
        }
    }
}

/// Syntax categories and their colours for tree-sitter tokens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SwiftSyntaxTokenKind {
    Keyword,
    TypeName,
    StringLiteral,
    Comment,
    Number,
    Attribute,
    Directive,
    FunctionName,
}

impl SwiftSyntaxTokenKind {
    pub const fn category(self) -> SyntaxCategory {
        match self {
            SwiftSyntaxTokenKind::Keyword => SyntaxCategory::Keyword,
            SwiftSyntaxTokenKind::TypeName => SyntaxCategory::Type,
            SwiftSyntaxTokenKind::StringLiteral => SyntaxCategory::String,
            SwiftSyntaxTokenKind::Comment => SyntaxCategory::Comment,
            SwiftSyntaxTokenKind::Number => SyntaxCategory::Number,
            SwiftSyntaxTokenKind::Attribute => SyntaxCategory::Attribute,
            SwiftSyntaxTokenKind::Directive => SyntaxCategory::Directive,
            SwiftSyntaxTokenKind::FunctionName => SyntaxCategory::Function,
        }
    }

    pub fn color(self, light: bool, palette: &BTreeMap<String, Color>) -> Color {
        self.category().color(light, palette)
    }
}
