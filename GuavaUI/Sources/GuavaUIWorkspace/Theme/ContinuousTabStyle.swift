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

/// A full-height tab with a quiet top accent, without a nested selection pill.
struct WorkspaceContinuousTabStyle: ButtonStyle {
    let height: Float

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
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
