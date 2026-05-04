import Testing
@testable import GuavaUICompose

@Suite("KeyboardShortcut")
struct KeyboardShortcutTests {
    @Test("Primary modifier displays as Command on macOS")
    func macOSPrimaryDisplay() {
        #expect(KeyboardShortcut.primary("D").displayString(platform: .macOS) == "⌘D")
        #expect(KeyboardShortcut.primaryShift("T").displayString(platform: .macOS) == "⌘⇧T")
    }

    @Test("Primary modifier displays as Control on non-mac platforms")
    func nonMacPrimaryDisplay() {
        #expect(KeyboardShortcut.primary("D").displayString(platform: .windows) == "Ctrl+D")
        #expect(KeyboardShortcut.primaryShift("T").displayString(platform: .linux) == "Ctrl+Shift+T")
    }
}
