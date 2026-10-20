internal import GuavaUIRuntime

/// Decides who turns a key press into bytes.
///
/// Printable keys arrive twice from the platform: as a key event and as
/// composed text (layout- and IME-aware). The text path owns them, so the key
/// event is swallowed. Everything else — editing keys, arrows, function keys
/// and Control chords — goes through Ghostty's encoder, which follows the
/// program's keyboard modes.
enum KeyRouting: Equatable {
    /// Consume the key; the matching text event will deliver the bytes.
    case text
    /// Encode with the terminal's key encoder.
    case encode(TerminalKey)
    /// Leave it to the host (Command shortcuts).
    case host
    case paste

    init(_ event: KeyEvent) {
        let modifiers = event.modifiers
        if modifiers.hasGui {
            self = event.scancode == 25 && !modifiers.hasShift && !modifiers.hasCtrl ? .paste : .host
            return
        }
        var terminalModifiers: TerminalKey.Modifiers = []
        if modifiers.hasShift { terminalModifiers.insert(.shift) }
        if modifiers.hasCtrl { terminalModifiers.insert(.control) }
        if modifiers.hasAlt { terminalModifiers.insert(.option) }

        let unshifted = Self.unshiftedText[event.scancode]
        if unshifted != nil, !modifiers.hasCtrl, !Self.altEncodesEscape(modifiers) {
            self = .text
            return
        }
        self = .encode(TerminalKey(scancode: event.scancode, modifiers: terminalModifiers,
                                   text: unshifted ?? "", isRepeat: event.isRepeat))
    }

    /// macOS Option composes characters (Option-3 = £ on a UK layout), so it
    /// stays on the text path; elsewhere Alt sends an ESC prefix.
    private static func altEncodesEscape(_ modifiers: KeyModifiers) -> Bool {
        #if os(macOS)
        false
        #else
        modifiers.hasAlt
        #endif
    }

    /// US-layout characters for keys that produce text, keyed by HID usage id.
    /// Used as the key's unshifted codepoint (Control chords, Kitty protocol).
    private static let unshiftedText: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        for (offset, scalar) in "abcdefghijklmnopqrstuvwxyz".enumerated() { table[4 + UInt32(offset)] = String(scalar) }
        for (offset, scalar) in "1234567890".enumerated() { table[30 + UInt32(offset)] = String(scalar) }
        for (scancode, text) in [(44, " "), (45, "-"), (46, "="), (47, "["), (48, "]"), (49, "\\"),
                                 (51, ";"), (52, "'"), (53, "`"), (54, ","), (55, "."), (56, "/"),
                                 (84, "/"), (85, "*"), (86, "-"), (87, "+"), (89, "1"), (90, "2"),
                                 (91, "3"), (92, "4"), (93, "5"), (94, "6"), (95, "7"), (96, "8"),
                                 (97, "9"), (98, "0"), (99, "."), (100, "\\"), (103, "=")] as [(UInt32, String)] {
            table[scancode] = text
        }
        return table
    }()
}
