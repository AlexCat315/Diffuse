import GuavaKit
import GuavaKitHost

// MARK: - Editor Shell

/// Main editor dock layout: sidebar (left) | content (center) | inspector (right)
/// with a console panel spanning the bottom.
///
/// Replaces the legacy `WorkspaceView` dock system.
public struct EditorShell: GuavaKit.View {
    @GuavaKit.State var leftWidth: Float = 260
    @GuavaKit.State var rightWidth: Float = 300
    @GuavaKit.State var bottomHeight: Float = 200
    @GuavaKit.State var activeBottomTab: String = "Console"

    public init() {}

    public var body: some GuavaKit.View {
        GuavaKit.Stack(.column) {
            // ── Top: left | center | right ──
            editorTopRow

            // ── Bottom: console / output ──
            bottomPanel
        }
    }

    // MARK: - Top row (three-column layout)

    @GuavaKit.ViewBuilder
    private var editorTopRow: some GuavaKit.View {
        GuavaKit.Stack(.row) {
            // ── Left sidebar ──
            panelGroup(title: "Hierarchy", width: leftWidth) {
                placeholderContent("Scene Hierarchy", icon: "🌳")
            }

            // ── Center (viewport + toolbar) ──
            centerArea

            // ── Right sidebar ──
            GuavaKit.Stack(.column) {
                panelGroup(title: "Inspector", width: rightWidth) {
                    placeholderContent("Inspector", icon: "🔍")
                }
                panelGroup(title: "Assets", width: rightWidth) {
                    placeholderContent("Asset Browser", icon: "📦")
                }
            }
        }
    }

    // MARK: - Center area

    @GuavaKit.ViewBuilder
    private var centerArea: some GuavaKit.View {
        GuavaKit.Stack(.column) {
            // Toolbar
            editorToolbar
            // Viewport placeholder
            placeholderContent("3D Viewport", icon: "🎮").background(GuavaKit.Color(r: 0.06, g: 0.06, b: 0.08))
        }
    }

    // MARK: - Toolbar

    @GuavaKit.ViewBuilder
    private var editorToolbar: some GuavaKit.View {
        GuavaKit.Stack(.row, spacing: 4) {
            toolbarButton("▶")
            toolbarButton("⏸")
            toolbarButton("⏹")
            GuavaKit.Spacer()
            GuavaKit.Text("GuavaNext Editor", color: GuavaKit.Color(r: 0.5, g: 0.5, b: 0.6), fontSize: 11)
            GuavaKit.Spacer()
            toolbarButton("⚙")
        }
    }

    // MARK: - Bottom panel

    @GuavaKit.ViewBuilder
    private var bottomPanel: some GuavaKit.View {
        GuavaKit.Stack(.column) {
            GuavaKit.Divider(color: GuavaKit.Color(r: 0.2, g: 0.2, b: 0.25))
            // Tab bar
            bottomTabBar
            // Content
            bottomContent
        }.frame(height: bottomHeight)
    }

    @GuavaKit.ViewBuilder
    private var bottomTabBar: some GuavaKit.View {
        GuavaKit.Stack(.row, spacing: 0) {
            bottomTab("Console")
            bottomTab("Output")
            GuavaKit.Spacer()
        }
        .background(GuavaKit.Color(r: 0.12, g: 0.12, b: 0.16))
    }

    private func bottomTab(_ name: String) -> some GuavaKit.View {
        let isActive = name == activeBottomTab
        return GuavaKit.Button(action: { activeBottomTab = name }) {
            GuavaKit.Text(name, fontSize: 12)
                .foregroundColor(isActive ? GuavaKit.Color(r: 1, g: 1, b: 1) : GuavaKit.Color(r: 0.4, g: 0.4, b: 0.5))
                .padding(Edges.all(8))
                .background(isActive ? GuavaKit.Color(r: 0.16, g: 0.16, b: 0.20) : GuavaKit.Color(r: 0, g: 0, b: 0, a: 0))
        }
    }

    @GuavaKit.ViewBuilder
    private var bottomContent: some GuavaKit.View {
        GuavaKit.ScrollView(.column) {
            consoleOutput
        }
    }

    // MARK: - Helpers

    private func panelGroup<Content: GuavaKit.View>(title: String, width: Float,
                                                      @GuavaKit.ViewBuilder content: () -> Content) -> some GuavaKit.View {
        GuavaKit.Stack(.column) {
            // Panel header
            GuavaKit.Stack(.row, spacing: 4) {
                GuavaKit.Text(title, color: GuavaKit.Color(r: 0.6, g: 0.6, b: 0.7), fontSize: 11)
                GuavaKit.Spacer()
            }
            GuavaKit.Divider(color: GuavaKit.Color(r: 0.18, g: 0.18, b: 0.22))
            // Panel body
            content()
                .background(GuavaKit.Color(r: 0.10, g: 0.10, b: 0.13))
        }
        .frame(width: width)
        .background(GuavaKit.Color(r: 0.10, g: 0.10, b: 0.13))
    }

    private func toolbarButton(_ label: String) -> some GuavaKit.View {
        GuavaKit.Button(action: {}) {
            GuavaKit.Text(label, fontSize: 14)
                .foregroundColor(GuavaKit.Color(r: 0.7, g: 0.7, b: 0.8))
                .padding(Edges.all(4))
        }
    }

    private func placeholderContent(_ title: String, icon: String) -> some GuavaKit.View {
        GuavaKit.Stack(.column, spacing: 8) {
            GuavaKit.Text(icon, fontSize: 32)
            GuavaKit.Text(title, color: GuavaKit.Color(r: 0.4, g: 0.4, b: 0.5), fontSize: 13)
        }
    }

    // Placeholder console output.
    @GuavaKit.ViewBuilder
    private var consoleOutput: some GuavaKit.View {
        GuavaKit.Stack(.column, spacing: 1) {
            consoleLine("[GuavaKit] EditorShell initialized", type: .info)
            consoleLine("[GuavaKit] Dock layout: left(260) | center(flex) | right(300)", type: .info)
            consoleLine("[GuavaKit] Bottom panel: Console + Output tabs", type: .info)
            consoleLine("", type: .info)
            consoleLine("// Welcome to GuavaKit v2 Editor", type: .info)
            consoleLine("// Architecture:", type: .info)
            consoleLine("//   SDL3 → EventAdapter → ViewGraph → Painter → DisplayListRenderer → wgpu", type: .muted)
            consoleLine("", type: .info)
            consoleLine("// Single funnel: setGeometry() → DirtyFlags → invalidate", type: .muted)
            consoleLine("// Scoped context: UIContext per window, no globals", type: .muted)
            consoleLine("// Lifecycle: NodeResource mounts/detaches with node tree", type: .muted)
            consoleLine("", type: .info)
            for i in 1...15 {
                consoleLine("log line \(i): all systems nominal", type: .info)
            }
        }
    }

    private enum ConsoleLineType { case info, warn, error, muted }

    private func consoleLine(_ text: String, type: ConsoleLineType = .info) -> some GuavaKit.View {
        let color: GuavaKit.Color
        switch type {
        case .info:  color = GuavaKit.Color(r: 0.7, g: 0.7, b: 0.7)
        case .warn:  color = GuavaKit.Color(r: 1, g: 0.8, b: 0.2)
        case .error: color = GuavaKit.Color(r: 1, g: 0.25, b: 0.25)
        case .muted: color = GuavaKit.Color(r: 0.35, g: 0.35, b: 0.40)
        }
        return GuavaKit.Text(text, color: color, fontSize: 12)
    }
}
