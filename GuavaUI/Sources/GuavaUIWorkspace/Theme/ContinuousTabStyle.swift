import GuavaUICompose
import GuavaUIRuntime

struct WorkspacePanelStyleReader<Content: View>: _PrimitiveView {
    let content: (WorkspacePanelStyle) -> Content
    init(@ViewBuilder content: @escaping (WorkspacePanelStyle) -> Content) { self.content = content }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {}
    func _children(for node: Node) -> [any View] { [content(resolveWorkspaceTheme(on: node).panelStyle)] }
}

/// Stage tabs follow documents; tool panes use compact selection blocks.
struct WorkspaceContinuousTabStyle: ButtonStyle {
    let height: Float
    var isStage = true

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        if !isStage {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                AnyView(configuration.label)
            }
            .padding(horizontal: 9)
            .frame(height: height - 8)
            .background(configuration.isSelected ? colors.surfaceVariant
                : configuration.isHovered ? colors.stateLayerHover : .clear)
            .cornerRadius(6)
            .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        } else {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Box {}.frame(height: 2)
                    .background(configuration.isSelected ? colors.accent : .clear)
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    AnyView(configuration.label)
                }.padding(horizontal: 11).flex()
            }
            .frame(height: height)
            .background(configuration.isSelected ? colors.surfaceSunken
                : configuration.isHovered ? colors.stateLayerHover : .clear)
            .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        }
    }
}
