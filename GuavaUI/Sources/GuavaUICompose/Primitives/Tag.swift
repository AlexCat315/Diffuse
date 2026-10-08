import GuavaUIRuntime

public struct Tag: View {
    public let title: String
    public var tone: StatusTone = .neutral
    public var isEnabled = true
    public var onRemove: (() -> Void)?
    public init(_ title: String, configure: (inout Self) -> Void = { _ in }) { self.title = title; configure(&self) }
    public var body: some View {
        Row(alignment: .center, spacing: 5) {
            Text(title).font(.caption).foregroundColor(tone.color)
            if let onRemove {
                Button(icon: .resource(UICommonIcons.close), size: 10, isEnabled: isEnabled, tooltip: "Remove \(title)", action: onRemove)
                    .buttonStyle(.ghost).controlSize(.mini).accessibilityLabel("Remove \(title)")
            }
        }.padding(horizontal: 8, vertical: 3).background(tone.color.opacity(0.12)).cornerRadius(6)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

public struct KeyCap: View {
    public let title: String
    public init(_ title: String) { self.title = title }
    public init(_ shortcut: KeyboardShortcut) { title = shortcut.displayString }
    public var body: some View {
        Text(title).font(.caption).foregroundColor(.onSurfaceMuted).padding(horizontal: 6, vertical: 3)
            .background(.surfaceVariant).cornerRadius(4).border(.border, width: 1)
    }
}
