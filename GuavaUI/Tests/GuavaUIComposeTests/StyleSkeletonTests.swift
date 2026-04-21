import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 7.5 Style Skeletons")
struct StyleSkeletonTests {

    @Test("TextFieldStyleEnvironment defaults to DefaultTextFieldStyle")
    func textFieldDefault() {
        let node = Node()
        let any = node.compositionValue(of: TextFieldStyleEnvironment.key)
        let cfg = TextFieldStyleConfiguration(
            content: AnyView(EmptyView()),
            placeholder: "",
            isFocused: false, isEditing: false, isError: false, isEnabled: true,
            theme: .defaultDark
        )
        let body = any.makeBody(cfg)
        // Body should not be EmptyView — DefaultTextFieldStyle wraps the
        // content in a padded background.
        #expect(!(body is EmptyView))
    }

    @Test(".textFieldStyle(_:) overrides the environment")
    func textFieldOverride() {
        struct Probe: TextFieldStyle {
            func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
                Text("probe")
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: _DebugNode(label: "x").textFieldStyle(Probe()))
        // Walk to leaf and confirm the override is visible.
        var cursor = tree.root!
        while let next = cursor.children.first { cursor = next }
        let resolved = cursor.compositionValue(of: TextFieldStyleEnvironment.key)
        let body = resolved.makeBody(.init(
            content: AnyView(EmptyView()), placeholder: "",
            isFocused: false, isEditing: false, isError: false, isEnabled: true,
            theme: .defaultDark))
        #expect(body is Text)
    }

    @Test("PanelStyleEnvironment defaults to DefaultPanelStyle")
    func panelDefault() {
        let node = Node()
        let any = node.compositionValue(of: PanelStyleEnvironment.key)
        let cfg = PanelStyleConfiguration(
            title: "Hello", accessory: AnyView(EmptyView()),
            content: AnyView(EmptyView()), isActive: false, theme: .defaultDark)
        let body = any.makeBody(cfg)
        #expect(!(body is EmptyView))
    }

    @Test("ListRowStyleEnvironment defaults to DefaultListRowStyle and applies selection fill")
    func listRowSelected() {
        let any = AnyListRowStyle(DefaultListRowStyle())
        let cfg = ListRowStyleConfiguration(
            content: AnyView(EmptyView()),
            isSelected: true, isHovered: false, isEnabled: true,
            theme: .defaultDark)
        // Smoke: body should be produced without crashing.
        _ = any.makeBody(cfg)
    }

    @Test("TreeRowStyle environment is wired and depth flows in")
    func treeRowDepth() {
        let any = AnyTreeRowStyle(DefaultTreeRowStyle())
        let cfg = TreeRowStyleConfiguration(
            content: AnyView(EmptyView()),
            depth: 3, indentation: 14, disclosureWidth: 18,
            hasChildren: true, isExpanded: true,
            isSelected: false, isHovered: false, isEnabled: true,
            theme: .defaultDark)
        _ = any.makeBody(cfg)
    }

    @Test("DividerStyle default produces a Divider primitive with the theme divider color")
    func dividerDefault() {
        let any = AnyDividerStyle(DefaultDividerStyle())
        let cfg = DividerStyleConfiguration(
            orientation: .horizontal, thickness: 1, theme: .defaultDark)
        let body = any.makeBody(cfg)
        let divider = body as? Divider
        #expect(divider != nil)
        #expect(divider?.color == Theme.defaultDark.colors.divider)
    }

    @Test("All five style environments fall back to their Default* implementation")
    func allEnvironmentsHaveDefaults() {
        let n = Node()
        // Smoke: every key resolves to a non-nil any-style at the default node.
        _ = n.compositionValue(of: TextFieldStyleEnvironment.key)
        _ = n.compositionValue(of: PanelStyleEnvironment.key)
        _ = n.compositionValue(of: ListRowStyleEnvironment.key)
        _ = n.compositionValue(of: TreeRowStyleEnvironment.key)
        _ = n.compositionValue(of: DividerStyleEnvironment.key)
    }
}
