import Testing
import GuavaUIRuntime
@testable import GuavaUITerminal

@Suite("Key routing")
struct KeyRoutingTests {
    private func route(_ scancode: UInt32, _ modifiers: KeyModifiers = []) -> KeyRouting {
        KeyRouting(KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false))
    }

    @Test("Printable keys are left to composed text input")
    func printable() {
        #expect(route(4) == .text)
        #expect(route(4, .lshift) == .text)
        #expect(route(44) == .text)
        #expect(route(30, .lshift) == .text)
    }

    @Test("Control chords and editing keys are encoded")
    func encoded() {
        #expect(route(6, .lctrl) == .encode(TerminalKey(scancode: 6, modifiers: .control, text: "c")))
        #expect(route(82) == .encode(TerminalKey(scancode: 82)))
        #expect(route(40) == .encode(TerminalKey(scancode: 40)))
        #expect(route(43, .lshift) == .encode(TerminalKey(scancode: 43, modifiers: .shift)))
    }

    @Test("Command shortcuts belong to the host except copy and paste")
    func command() {
        #expect(route(25, .lgui) == .paste)
        #expect(route(6, .lgui) == .copy)
        #expect(route(6, [.lgui, .lalt]) == .host)
        #expect(route(17, .lgui) == .host)
        #expect(route(25, [.lgui, .lshift]) == .host)
    }

    @Test("Option composes on macOS, sends ESC elsewhere")
    func option() {
        #if os(macOS)
        #expect(route(4, .lalt) == .text)
        #else
        #expect(route(4, .lalt) == .encode(TerminalKey(scancode: 4, modifiers: .option, text: "a")))
        #endif
    }
}
