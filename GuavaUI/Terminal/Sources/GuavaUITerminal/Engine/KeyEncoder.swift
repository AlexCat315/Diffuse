internal import GhosttyVt

/// A physical key press as the terminal sees it. `scancode` is the USB HID
/// usage id (SDL scancode); `text` is what the key would type unmodified.
struct TerminalKey: Equatable, Sendable {
    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    var scancode: UInt32
    var modifiers: Modifiers = []
    var text = ""
    var isRepeat = false
}

/// Wraps a Ghostty key encoder so the bytes follow the terminal's live modes
/// (application cursor keys, keypad mode, Kitty keyboard flags, ...).
final class KeyEncoder {
    private let encoder: GhosttyKeyEncoder
    private let event: GhosttyKeyEvent

    init() {
        var encoder: GhosttyKeyEncoder?
        var event: GhosttyKeyEvent?
        precondition(ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS, "libghostty-vt: key encoder failed")
        precondition(ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS, "libghostty-vt: key event failed")
        self.encoder = encoder!
        self.event = event!
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    func encode(_ key: TerminalKey, terminal: GhosttyTerminal) -> [UInt8] {
        guard let ghosttyKey = Self.keys[key.scancode] else { return [] }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        ghostty_key_event_set_action(event, key.isRepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, ghosttyKey)
        ghostty_key_event_set_mods(event, Self.mods(key.modifiers))
        ghostty_key_event_set_consumed_mods(event, 0)
        ghostty_key_event_set_composing(event, false)
        ghostty_key_event_set_unshifted_codepoint(event, key.text.unicodeScalars.first.map { $0.value } ?? 0)

        var utf8 = Array(key.text.utf8)
        return utf8.withUnsafeMutableBufferPointer { text -> [UInt8] in
            text.withMemoryRebound(to: CChar.self) { chars in
                ghostty_key_event_set_utf8(event, chars.baseAddress, chars.count)
                var buffer = [CChar](repeating: 0, count: 128)
                var written = 0
                var result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &written)
                if result == GHOSTTY_OUT_OF_SPACE {
                    buffer = [CChar](repeating: 0, count: written)
                    result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &written)
                }
                // The event borrows `text`; drop the pointer before it dies.
                ghostty_key_event_set_utf8(event, nil, 0)
                guard result == GHOSTTY_SUCCESS else { return [] }
                return buffer.prefix(written).map { UInt8(bitPattern: $0) }
            }
        }
    }

    private static func mods(_ modifiers: TerminalKey.Modifiers) -> GhosttyMods {
        var mods: GhosttyMods = 0
        if modifiers.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if modifiers.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if modifiers.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if modifiers.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        return mods
    }

    /// USB HID usage id → W3C key code, as Ghostty names them.
    private static let keys: [UInt32: GhosttyKey] = {
        var table: [UInt32: GhosttyKey] = [:]
        let letters: [GhosttyKey] = [
            GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D, GHOSTTY_KEY_E, GHOSTTY_KEY_F,
            GHOSTTY_KEY_G, GHOSTTY_KEY_H, GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
            GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P, GHOSTTY_KEY_Q, GHOSTTY_KEY_R,
            GHOSTTY_KEY_S, GHOSTTY_KEY_T, GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
            GHOSTTY_KEY_Y, GHOSTTY_KEY_Z,
        ]
        for (offset, key) in letters.enumerated() { table[4 + UInt32(offset)] = key }
        let digits: [GhosttyKey] = [
            GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3, GHOSTTY_KEY_DIGIT_4,
            GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8,
            GHOSTTY_KEY_DIGIT_9, GHOSTTY_KEY_DIGIT_0,
        ]
        for (offset, key) in digits.enumerated() { table[30 + UInt32(offset)] = key }
        let functions: [GhosttyKey] = [
            GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4, GHOSTTY_KEY_F5, GHOSTTY_KEY_F6,
            GHOSTTY_KEY_F7, GHOSTTY_KEY_F8, GHOSTTY_KEY_F9, GHOSTTY_KEY_F10, GHOSTTY_KEY_F11, GHOSTTY_KEY_F12,
        ]
        for (offset, key) in functions.enumerated() { table[58 + UInt32(offset)] = key }
        let keypad: [GhosttyKey] = [
            GHOSTTY_KEY_NUMPAD_DIVIDE, GHOSTTY_KEY_NUMPAD_MULTIPLY, GHOSTTY_KEY_NUMPAD_SUBTRACT,
            GHOSTTY_KEY_NUMPAD_ADD, GHOSTTY_KEY_NUMPAD_ENTER, GHOSTTY_KEY_NUMPAD_1, GHOSTTY_KEY_NUMPAD_2,
            GHOSTTY_KEY_NUMPAD_3, GHOSTTY_KEY_NUMPAD_4, GHOSTTY_KEY_NUMPAD_5, GHOSTTY_KEY_NUMPAD_6,
            GHOSTTY_KEY_NUMPAD_7, GHOSTTY_KEY_NUMPAD_8, GHOSTTY_KEY_NUMPAD_9, GHOSTTY_KEY_NUMPAD_0,
            GHOSTTY_KEY_NUMPAD_DECIMAL,
        ]
        for (offset, key) in keypad.enumerated() { table[84 + UInt32(offset)] = key }
        let named: [(UInt32, GhosttyKey)] = [
            (40, GHOSTTY_KEY_ENTER), (41, GHOSTTY_KEY_ESCAPE), (42, GHOSTTY_KEY_BACKSPACE),
            (43, GHOSTTY_KEY_TAB), (44, GHOSTTY_KEY_SPACE), (45, GHOSTTY_KEY_MINUS), (46, GHOSTTY_KEY_EQUAL),
            (47, GHOSTTY_KEY_BRACKET_LEFT), (48, GHOSTTY_KEY_BRACKET_RIGHT), (49, GHOSTTY_KEY_BACKSLASH),
            (51, GHOSTTY_KEY_SEMICOLON), (52, GHOSTTY_KEY_QUOTE), (53, GHOSTTY_KEY_BACKQUOTE),
            (54, GHOSTTY_KEY_COMMA), (55, GHOSTTY_KEY_PERIOD), (56, GHOSTTY_KEY_SLASH),
            (73, GHOSTTY_KEY_INSERT), (74, GHOSTTY_KEY_HOME), (75, GHOSTTY_KEY_PAGE_UP),
            (76, GHOSTTY_KEY_DELETE), (77, GHOSTTY_KEY_END), (78, GHOSTTY_KEY_PAGE_DOWN),
            (79, GHOSTTY_KEY_ARROW_RIGHT), (80, GHOSTTY_KEY_ARROW_LEFT),
            (81, GHOSTTY_KEY_ARROW_DOWN), (82, GHOSTTY_KEY_ARROW_UP),
            (100, GHOSTTY_KEY_INTL_BACKSLASH), (103, GHOSTTY_KEY_NUMPAD_EQUAL),
        ]
        for (scancode, key) in named { table[scancode] = key }
        return table
    }()
}
