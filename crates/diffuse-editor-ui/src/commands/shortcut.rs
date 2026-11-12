//! Translation of Editor/Sources/EditorUI/Commands/Shortcut.swift.
//!
//! A key chord declared once in the command catalog. The same value feeds the
//! native menu key equivalent, the title-bar and palette labels, and the
//! in-window shortcut dispatch used when no native menu owns the key.

use cove_platform::KeyEvent;
use cove_ui::NativeMenuKeyModifiers;
use cove_ui_compose::Scancode;

/// A key chord.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorShortcut {
    pub key: EditorShortcutKey,
    pub modifiers: EditorKeyModifiers,
}

impl EditorShortcut {
    /// Swift's `init(_:_:)` with the `.primary` default.
    pub fn new(key: EditorShortcutKey) -> Self {
        EditorShortcut {
            key,
            modifiers: EditorKeyModifiers::primary(),
        }
    }

    pub fn with_modifiers(key: EditorShortcutKey, modifiers: EditorKeyModifiers) -> Self {
        EditorShortcut { key, modifiers }
    }

    pub fn label(&self) -> String {
        #[cfg(target_os = "macos")]
        {
            let mut text = String::new();
            if self.modifiers.contains(EditorKeyModifiers::CONTROL) {
                text.push('⌃');
            }
            if self.modifiers.contains(EditorKeyModifiers::OPTION) {
                text.push('⌥');
            }
            if self.modifiers.contains(EditorKeyModifiers::SHIFT) {
                text.push('⇧');
            }
            if self.modifiers.contains(EditorKeyModifiers::COMMAND) {
                text.push('⌘');
            }
            text.push_str(&self.key.symbol);
            text
        }
        #[cfg(not(target_os = "macos"))]
        {
            let mut parts: Vec<&str> = Vec::new();
            if self.modifiers.contains(EditorKeyModifiers::CONTROL) {
                parts.push("Ctrl");
            }
            if self.modifiers.contains(EditorKeyModifiers::SHIFT) {
                parts.push("Shift");
            }
            if self.modifiers.contains(EditorKeyModifiers::OPTION) {
                parts.push("Alt");
            }
            if self.modifiers.contains(EditorKeyModifiers::COMMAND) {
                parts.push("Meta");
            }
            parts.push(&self.key.name);
            parts.join("+")
        }
    }

    /// The primary modifier accepts either Command or Control so a chord keeps
    /// working on keyboards and remote sessions that swap the two.
    pub fn matches(&self, event: &KeyEvent) -> bool {
        if !self.key.scancodes.contains(&event.scancode) {
            return false;
        }
        let mods = event.modifiers;
        if self.modifiers.is_empty() {
            return mods.is_empty();
        }
        let wants_primary = self.modifiers.contains(EditorKeyModifiers::primary());
        if (mods.has_gui() || mods.has_ctrl()) != wants_primary {
            return false;
        }
        mods.has_shift() == self.modifiers.contains(EditorKeyModifiers::SHIFT)
            && mods.has_alt() == self.modifiers.contains(EditorKeyModifiers::OPTION)
    }
}

/// Physical key plus the spellings each presentation needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorShortcutKey {
    /// AppKit key equivalent.
    pub equivalent: String,
    pub symbol: String,
    pub name: String,
    pub scancodes: Vec<u32>,
}

impl EditorShortcutKey {
    pub fn letter(character: char) -> Self {
        let lower = character.to_ascii_lowercase();
        let offset = u32::from(lower as u8).wrapping_sub(u32::from(b'a'));
        let lower_text = lower.to_string();
        EditorShortcutKey {
            equivalent: lower_text.clone(),
            symbol: lower_text.to_uppercase(),
            name: lower_text.to_uppercase(),
            scancodes: vec![Scancode::A + offset],
        }
    }

    pub fn digit(value: i64) -> Self {
        let scancode = if value == 0 {
            Scancode::DIGIT0
        } else {
            Scancode::DIGIT1 + (value - 1) as u32
        };
        EditorShortcutKey {
            equivalent: value.to_string(),
            symbol: value.to_string(),
            name: value.to_string(),
            scancodes: vec![scancode],
        }
    }

    fn fixed(equivalent: &str, symbol: &str, name: &str, scancodes: Vec<u32>) -> Self {
        EditorShortcutKey {
            equivalent: equivalent.to_string(),
            symbol: symbol.to_string(),
            name: name.to_string(),
            scancodes,
        }
    }

    pub fn comma() -> Self {
        Self::fixed(",", ",", ",", vec![Scancode::COMMA])
    }

    pub fn period() -> Self {
        Self::fixed(".", ".", ".", vec![Scancode::PERIOD])
    }

    pub fn space() -> Self {
        Self::fixed(" ", "Space", "Space", vec![Scancode::SPACE])
    }

    pub fn left_bracket() -> Self {
        Self::fixed("[", "[", "[", vec![Scancode::LEFT_BRACKET])
    }

    pub fn right_bracket() -> Self {
        Self::fixed("]", "]", "]", vec![Scancode::RIGHT_BRACKET])
    }

    /// SDL_SCANCODE_BACKSLASH; the shared scancode table has no name for it.
    pub fn backslash() -> Self {
        Self::fixed("\\", "\\", "\\", vec![49])
    }

    pub fn f2() -> Self {
        Self::fixed("\u{F705}", "F2", "F2", vec![Scancode::F2])
    }

    pub fn f12() -> Self {
        Self::fixed("\u{F70F}", "F12", "F12", vec![Scancode::F12])
    }

    pub fn delete() -> Self {
        Self::fixed(
            "\u{8}",
            "⌫",
            "Delete",
            vec![Scancode::BACKSPACE, Scancode::DELETE],
        )
    }

    pub fn enter() -> Self {
        Self::fixed(
            "\r",
            "↩",
            "Enter",
            vec![Scancode::RETURN, Scancode::KEYPAD_ENTER],
        )
    }
}

/// Swift's `OptionSet`; `rawValue` is a byte so every chord fits in one value.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct EditorKeyModifiers(pub u8);

impl EditorKeyModifiers {
    pub const COMMAND: Self = Self(1 << 0);
    pub const SHIFT: Self = Self(1 << 1);
    pub const OPTION: Self = Self(1 << 2);
    pub const CONTROL: Self = Self(1 << 3);

    pub const fn primary() -> Self {
        #[cfg(target_os = "macos")]
        {
            Self::COMMAND
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self::CONTROL
        }
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub fn native(self) -> NativeMenuKeyModifiers {
        let mut out = NativeMenuKeyModifiers(0);
        if self.contains(Self::COMMAND) {
            out = out.union(NativeMenuKeyModifiers::COMMAND);
        }
        if self.contains(Self::SHIFT) {
            out = out.union(NativeMenuKeyModifiers::SHIFT);
        }
        if self.contains(Self::OPTION) {
            out = out.union(NativeMenuKeyModifiers::OPTION);
        }
        if self.contains(Self::CONTROL) {
            out = out.union(NativeMenuKeyModifiers::CONTROL);
        }
        out
    }
}

impl std::ops::BitOr for EditorKeyModifiers {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}
