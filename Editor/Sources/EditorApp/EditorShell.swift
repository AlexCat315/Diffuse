import GuavaKit
import GuavaKitHost

// MARK: - Editor Shell

/// Main editor dock layout: sidebar (left) | content (center) | inspector (right)
/// with a console panel spanning the bottom. Fills the window: every region uses
/// `.flex`/stretch so it scales with the viewport instead of shrinking to content.
///
/// Replaces the legacy `WorkspaceView` dock system.
public struct EditorShell: GuavaKit.View {
    @GuavaKit.State var leftWidth: Float = 260
    @GuavaKit.State var rightWidth: Float = 300
    @GuavaKit.State var bottomHeight: Float = 200
    @GuavaKit.State var activeBottomTab: String = "Console"

    public init() {}

    public var body: some GuavaKit.View {
        GuavaKit.Column(alignment: .stretch, spacing: 0) {
            // ── Top: left | center | right (fills the space above the dock) ──
            editorTopRow.flex(1)
            // ── Bottom: console / output (fixed height) ──
            bottomPanel
        }
        .flex(1)
        .background(Palette.background)
    }

    // MARK: - Top row (three-column layout)

    @GuavaKit.ViewBuilder
    private var editorTopRow: some GuavaKit.View {
        GuavaKit.Row(alignment: .stretch, spacing: 0) {
            // ── Left sidebar ──
            panelGroup(title: "HIERARCHY") {
                placeholderContent("Scene Hierarchy", icon: "🌳")
            }
            .frame(width: leftWidth)

            // ── Center (viewport + toolbar) ──
            centerArea.flex(1)

            // ── Right sidebar ──
            GuavaKit.Column(alignment: .stretch, spacing: 0) {
                panelGroup(title: "INSPECTOR") {
                    placeholderContent("Inspector", icon: "🔍")
                }
                .flex(1)
                panelGroup(title: "ASSETS") {
                    placeholderContent("Asset Browser", icon: "📦")
                }
                .flex(1)
            }
            .frame(width: rightWidth)
        }
    }

    // MARK: - Center area

    @GuavaKit.ViewBuilder
    private var centerArea: some GuavaKit.View {
        GuavaKit.Column(alignment: .stretch, spacing: 0) {
            editorToolbar
            // Viewport placeholder — fills the remaining center space.
            GuavaKit.Column(alignment: .center, spacing: 8) {
                GuavaKit.Spacer()
                GuavaKit.Text("🎮", fontSize: 40)
                GuavaKit.Text("3D Viewport", color: Palette.textMuted, fontSize: 13)
                GuavaKit.Spacer()
            }
            .flex(1)
            .background(Palette.viewport)
        }
    }

    // MARK: - Toolbar

    @GuavaKit.ViewBuilder
    private var editorToolbar: some GuavaKit.View {
        GuavaKit.Row(alignment: .center, spacing: 4) {
            toolbarButton("▶")
            toolbarButton("⏸")
            toolbarButton("⏹")
            GuavaKit.Spacer()
            GuavaKit.Text("GuavaNext Editor", color: Palette.textMuted, fontSize: 11)
            GuavaKit.Spacer()
            toolbarButton("⚙")
        }
        .padding(GuavaKit.Edges.all(6))
        .background(Palette.surfaceVariant)
    }

    // MARK: - Bottom panel

    @GuavaKit.ViewBuilder
    private var bottomPanel: some GuavaKit.View {
        GuavaKit.Column(alignment: .stretch, spacing: 0) {
            GuavaKit.Divider(color: Palette.border)
            bottomTabBar
            bottomContent.flex(1)
        }
        .frame(height: bottomHeight)
        .background(Palette.surface)
    }

    @GuavaKit.ViewBuilder
    private var bottomTabBar: some GuavaKit.View {
        GuavaKit.Row(alignment: .center, spacing: 0) {
            bottomTab("Console")
            bottomTab("Output")
            GuavaKit.Spacer()
        }
        .background(Palette.surfaceSunken)
    }

    private func bottomTab(_ name: String) -> some GuavaKit.View {
        let isActive = name == activeBottomTab
        return GuavaKit.Button(action: { activeBottomTab = name }) {
            GuavaKit.Text(name, fontSize: 12)
                .foregroundColor(isActive ? Palette.text : Palette.textMuted)
                .padding(GuavaKit.Edges.all(8))
                .background(isActive ? Palette.surfaceVariant : Palette.clear)
        }
    }

    @GuavaKit.ViewBuilder
    private var bottomContent: some GuavaKit.View {
        GuavaKit.ScrollView(.column) {
            consoleOutput.padding(GuavaKit.Edges.all(8))
        }
        .background(Palette.surfaceSunken)
    }

    // MARK: - Helpers

    private func panelGroup<Content: GuavaKit.View>(title: String,
                                                    @GuavaKit.ViewBuilder content: () -> Content) -> some GuavaKit.View {
        GuavaKit.Column(alignment: .stretch, spacing: 0) {
            // Panel header
            GuavaKit.Row(alignment: .center, spacing: 4) {
                GuavaKit.Text(title, color: Palette.textMuted, fontSize: 11)
                GuavaKit.Spacer()
            }
            .padding(GuavaKit.Edges.all(8))
            GuavaKit.Divider(color: Palette.border)
            // Panel body — fills the rest of the panel.
            content().flex(1)
        }
        .background(Palette.surface)
    }

    private func toolbarButton(_ label: String) -> some GuavaKit.View {
        GuavaKit.Button(action: {}) {
            GuavaKit.Text(label, fontSize: 14)
                .foregroundColor(Palette.text)
                .padding(GuavaKit.Edges.all(6))
        }
    }

    private func placeholderContent(_ title: String, icon: String) -> some GuavaKit.View {
        GuavaKit.Column(alignment: .center, spacing: 8) {
            GuavaKit.Spacer()
            GuavaKit.Text(icon, fontSize: 28)
            GuavaKit.Text(title, color: Palette.textMuted, fontSize: 12)
            GuavaKit.Spacer()
        }
    }

    // Placeholder console output.
    @GuavaKit.ViewBuilder
    private var consoleOutput: some GuavaKit.View {
        GuavaKit.Column(alignment: .start, spacing: 2) {
            consoleLine("[GuavaKit] EditorShell initialized", .info)
            consoleLine("[GuavaKit] Dock: left(260) | center(flex) | right(300)", .info)
            consoleLine("// Welcome to GuavaKit v2 Editor", .muted)
            consoleLine("// SDL3 → EventAdapter → ViewGraph → Painter → wgpu", .muted)
            consoleLine("// Single funnel: setGeometry() → DirtyFlags → invalidate", .muted)
            consoleLine("// Lifecycle: NodeResource mounts/detaches with the tree", .muted)
            for i in 1...12 {
                consoleLine("log line \(i): all systems nominal", .info)
            }
        }
    }

    private enum ConsoleLineType { case info, warn, error, muted }

    private func consoleLine(_ text: String, _ type: ConsoleLineType = .info) -> some GuavaKit.View {
        let color: GuavaKit.Color
        switch type {
        case .info:  color = Palette.text
        case .warn:  color = GuavaKit.Color(r: 1, g: 0.8, b: 0.2)
        case .error: color = GuavaKit.Color(r: 1, g: 0.25, b: 0.25)
        case .muted: color = Palette.textMuted
        }
        return GuavaKit.Text(text, color: color, fontSize: 12)
    }
}

// MARK: - Palette (masterplan dark theme)

private enum Palette {
    static let background     = GuavaKit.Color(r: 0.075, g: 0.082, b: 0.102) // #13151A
    static let surface        = GuavaKit.Color(r: 0.106, g: 0.118, b: 0.141) // #1B1E24
    static let surfaceVariant = GuavaKit.Color(r: 0.137, g: 0.153, b: 0.184) // #23272F
    static let surfaceSunken  = GuavaKit.Color(r: 0.086, g: 0.094, b: 0.118) // #16181E
    static let viewport       = GuavaKit.Color(r: 0.055, g: 0.060, b: 0.075)
    static let border         = GuavaKit.Color(r: 0.165, g: 0.184, b: 0.220) // #2A2F38
    static let text           = GuavaKit.Color(r: 0.906, g: 0.922, b: 0.949) // #E7EBF2
    static let textMuted      = GuavaKit.Color(r: 0.529, g: 0.569, b: 0.627) // #8791A0
    static let clear          = GuavaKit.Color(r: 0, g: 0, b: 0, a: 0)
}
