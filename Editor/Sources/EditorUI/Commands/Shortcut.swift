internal import EngineKernel
internal import GuavaUI

/// A key chord declared once in the command catalog. The same value feeds the
/// native menu key equivalent, the title-bar and palette labels, and the
/// in-window shortcut dispatch used when no native menu owns the key.
struct EditorShortcut: Equatable {
    let key: EditorShortcutKey
    let modifiers: EditorKeyModifiers

    init(_ key: EditorShortcutKey, _ modifiers: EditorKeyModifiers = [.primary]) {
        self.key = key
        self.modifiers = modifiers
    }

    var label: String {
        #if os(macOS)
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.symbol
        #else
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.command) { parts.append("Meta") }
        parts.append(key.name)
        return parts.joined(separator: "+")
        #endif
    }

    /// The primary modifier accepts either Command or Control so a chord keeps
    /// working on keyboards and remote sessions that swap the two.
    func matches(_ event: KeyEvent) -> Bool {
        guard key.scancodes.contains(event.scancode) else { return false }
        let mods = event.modifiers
        if modifiers.isEmpty { return mods.isEmpty }
        let wantsPrimary = modifiers.contains(.primary)
        guard (mods.hasGui || mods.hasCtrl) == wantsPrimary else { return false }
        return mods.hasShift == modifiers.contains(.shift)
            && mods.hasAlt == modifiers.contains(.option)
    }
}

/// Physical key plus the spellings each presentation needs.
struct EditorShortcutKey: Equatable {
    /// AppKit key equivalent.
    let equivalent: String
    let symbol: String
    let name: String
    let scancodes: [UInt32]

    static func letter(_ character: Character) -> Self {
        let lower = Character(character.lowercased())
        let offset = UInt32(lower.asciiValue ?? 97) - 97
        return Self(equivalent: String(lower), symbol: lower.uppercased(), name: lower.uppercased(),
                    scancodes: [Scancode.a + offset])
    }

    static func digit(_ value: Int) -> Self {
        let scancode = value == 0 ? Scancode.digit0 : Scancode.digit1 + UInt32(value - 1)
        return Self(equivalent: String(value), symbol: String(value), name: String(value), scancodes: [scancode])
    }

    static let comma = Self(equivalent: ",", symbol: ",", name: ",", scancodes: [Scancode.comma])
    static let period = Self(equivalent: ".", symbol: ".", name: ".", scancodes: [Scancode.period])
    static let space = Self(equivalent: " ", symbol: "Space", name: "Space", scancodes: [Scancode.space])
    static let leftBracket = Self(equivalent: "[", symbol: "[", name: "[", scancodes: [Scancode.leftBracket])
    static let rightBracket = Self(equivalent: "]", symbol: "]", name: "]", scancodes: [Scancode.rightBracket])
    static let f2 = Self(equivalent: "\u{F705}", symbol: "F2", name: "F2", scancodes: [Scancode.f2])
    static let f12 = Self(equivalent: "\u{F70F}", symbol: "F12", name: "F12", scancodes: [Scancode.f12])
    static let delete = Self(equivalent: "\u{8}", symbol: "⌫", name: "Delete",
                             scancodes: [Scancode.backspace, Scancode.delete])
    static let enter = Self(equivalent: "\r", symbol: "↩", name: "Enter",
                            scancodes: [Scancode.return, Scancode.keypadEnter])
}

struct EditorKeyModifiers: OptionSet, Equatable {
    let rawValue: UInt8

    static let command = EditorKeyModifiers(rawValue: 1 << 0)
    static let shift = EditorKeyModifiers(rawValue: 1 << 1)
    static let option = EditorKeyModifiers(rawValue: 1 << 2)
    static let control = EditorKeyModifiers(rawValue: 1 << 3)

    #if os(macOS)
    static let primary: EditorKeyModifiers = .command
    #else
    static let primary: EditorKeyModifiers = .control
    #endif

    var native: NativeMenuKeyModifiers {
        var out: NativeMenuKeyModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}
