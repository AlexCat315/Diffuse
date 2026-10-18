import GuavaUIRuntime

/// Keyboard hint drawn as one cap per key.
///
/// Splitting a shortcut into caps — instead of printing `⌘⇧K` as a run of
/// text — is what lets the glyphs stay legible at caption size and keeps the
/// hint recognisable when the locale changes modifier names.
///
/// ```swift
/// KeyCap(.primary("S"))            // ⌘ S
/// KeyCap("Esc")
/// KeyCap(.primaryShift("P"), platform: .windows)   // Ctrl + Shift + P
/// ```
public struct KeyCap: View {
    public var keys: [String]
    public var platform: KeyboardShortcutPlatform
    public var isEnabled: Bool

    public init(_ keys: [String],
                platform: KeyboardShortcutPlatform = .current,
                configure: (inout Self) -> Void = { _ in }) {
        self.keys = keys
        self.platform = platform
        self.isEnabled = true
        configure(&self)
    }

    public init(_ title: String, configure: (inout Self) -> Void = { _ in }) {
        self.init([title], configure: configure)
    }

    public init(_ shortcut: KeyboardShortcut,
                platform: KeyboardShortcutPlatform = .current,
                configure: (inout Self) -> Void = { _ in }) {
        self.init(shortcut.caps(platform: platform), platform: platform, configure: configure)
    }

    public var body: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 2) {
            for key in keys {
                AnyView(cap(key))
            }
        }
        .accessibility {
            $0.role = .staticText
            $0.label = spokenForm; $0.combinesChildren = true
        }
    }

    @ViewBuilder private func cap(_ key: String) -> some View {
        Text(key)
            .font(.caption)
            .foregroundColor(isEnabled ? SemanticColorRef.onSurfaceVariant : .onSurfaceDisabled)
            .padding(horizontal: 6, vertical: 2)
            .background(SemanticColorRef.surfaceVariant)
            .cornerRadius(.rowRadius)
            .border(SemanticColorRef.border, width: 1)
            .opacity(isEnabled ? 1 : 0.55)
            .flex(0, shrink: 1).frame(minWidth: 0)
    }

    /// What a screen reader should announce: the spoken modifier names, never
    /// the bare glyphs.
    private var spokenForm: String {
        guard platform == .macOS else { return keys.joined(separator: " + ") }
        return keys.map { key in
            switch key {
            case "⌘": "Command"
            case "⌃": "Control"
            case "⌥": "Option"
            case "⇧": "Shift"
            default: key
            }
        }.joined(separator: " ")
    }
}
