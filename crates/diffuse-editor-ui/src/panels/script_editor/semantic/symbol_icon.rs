//! Translation of Editor/Sources/EditorUI/Panels/ScriptEditor/Semantic/SymbolIcon.swift.

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::primitives::media::ui_icon_catalog;

/// The glyph shown next to a document symbol, from its language-server kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptSymbolIcon {
    Type,
    Interface,
    Function,
    Property,
    Enumeration,
    Variable,
    Namespace,
    Value,
    Symbol,
}

impl ScriptSymbolIcon {
    /// `LSP.SymbolKind` numbers as the protocol defines them.
    pub fn from_kind(kind: i64) -> Self {
        match kind {
            5 | 23 => ScriptSymbolIcon::Type,
            11 => ScriptSymbolIcon::Interface,
            6 | 9 | 12 => ScriptSymbolIcon::Function,
            7 | 8 => ScriptSymbolIcon::Property,
            10 | 22 => ScriptSymbolIcon::Enumeration,
            13 | 14 => ScriptSymbolIcon::Variable,
            2..=4 => ScriptSymbolIcon::Namespace,
            15..=21 | 24..=26 => ScriptSymbolIcon::Value,
            _ => ScriptSymbolIcon::Symbol,
        }
    }

    pub fn resource(&self) -> BundleImageResource {
        match self {
            ScriptSymbolIcon::Type => ui_icon_catalog::editor::box_(),
            ScriptSymbolIcon::Interface => ui_icon_catalog::editor::git_merge(),
            ScriptSymbolIcon::Function => ui_icon_catalog::editor::code(),
            ScriptSymbolIcon::Property => ui_icon_catalog::action::sliders(),
            ScriptSymbolIcon::Enumeration => ui_icon_catalog::text::list(),
            ScriptSymbolIcon::Variable => ui_icon_catalog::shape::hash(),
            ScriptSymbolIcon::Namespace => ui_icon_catalog::file::package(),
            ScriptSymbolIcon::Value => ui_icon_catalog::text::type_(),
            ScriptSymbolIcon::Symbol => ui_icon_catalog::file::file_code(),
        }
    }
}
