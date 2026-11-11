//! Translation of Editor/Sources/EditorUI/Root/Chrome/EditorVisualTheme.swift.

use cove_ui_compose::scene_core::Color;
use cove_ui_compose::theme::Theme;
use diffuse_editor_core::contributions::themes::theme_catalog::EditorThemeCatalog;

pub struct EditorVisualTheme;

impl EditorVisualTheme {
    pub fn make(dark: bool) -> Theme {
        Self::make_with_theme_id(dark, EditorThemeCatalog::DEFAULT_THEME_ID)
    }

    /// `make(dark:themeID:)` with Swift's default theme ID.
    pub fn make_with_theme_id(dark: bool, theme_id: &str) -> Theme {
        EditorThemeCatalog::bundled_theme(theme_id, dark)
    }
}

/// Base colors for the editor's dark theme. Source panes resolve their colors
/// through the active semantic theme, including the light palette.
pub struct EditorCodePalette;

impl EditorCodePalette {
    pub const BACKGROUND: Color = Color::from_rgba8(0x17, 0x1C, 0x1B, 0xFF);
    pub const GUTTER: Color = Color::from_rgba8(0x11, 0x15, 0x15, 0xFF);
    pub const HEADER: Color = Color::from_rgba8(0x1D, 0x23, 0x21, 0xFF);
    pub const SELECTED_TAB: Color = Color::from_rgba8(0x33, 0x3A, 0x37, 0xFF);
    pub const FOREGROUND: Color = Color::from_rgba8(0xEC, 0xEF, 0xED, 0xFF);
    pub const MUTED: Color = Color::from_rgba8(0x8B, 0x94, 0x8F, 0xFF);
    pub const LINE_NUMBER: Color = Color::from_rgba8(0x71, 0x79, 0x76, 0xFF);
    pub const ACCENT: Color = Color::from_rgba8(0x5F, 0xAF, 0x82, 0xFF);
}
