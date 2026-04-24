import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 8 / Theme cross-fade by component", .serialized)
struct ThemeCrossFadeComponentTests: GuavaUIComposeSerializedSuite {

    struct _ListItem: Identifiable {
        let id: Int
        let title: String
    }

    struct _TreeItem: Identifiable {
        let id: String
        let title: String
        let children: [_TreeItem]
    }

    struct ListHarness: View {
        @State var appearance: Appearance = .dark
        let items: [_ListItem] = [
            _ListItem(id: 1, title: "One"),
            _ListItem(id: 2, title: "Two")
        ]

        var body: some View {
            List(items, selection: .constant(2)) { row, _ in
                Text(row.title)
            }
            .appearance(appearance)
            .animation(.easeInOut(duration: 0.30), value: appearance)
        }
    }

    struct TreeHarness: View {
        @State var appearance: Appearance = .dark
        @State var selection: String? = "camera"
        let roots: [_TreeItem] = [
            _TreeItem(id: "camera", title: "Camera", children: []),
            _TreeItem(id: "light", title: "Light", children: [])
        ]

        var body: some View {
            Tree(roots,
                 children: \.children,
                 selection: $selection) { item, _, _, _ in
                Text(item.title)
            }
            .appearance(appearance)
            .animation(.easeInOut(duration: 0.30), value: appearance)
        }
    }

    struct TextFieldHarness: View {
        @State var appearance: Appearance = .dark
        @State var text: String = ""

        var body: some View {
            TextField("Name", text: $text)
                .appearance(appearance)
                .animation(.easeInOut(duration: 0.30), value: appearance)
        }
    }

    struct TabHarness: View {
        @State var appearance: Appearance = .dark
        @State var selection: Int = 0

        var body: some View {
            TabView(selection: $selection, tabs: [
                TabItem("A", id: 0) { EmptyView() },
                TabItem("B", id: 1) { EmptyView() }
            ])
            .appearance(appearance)
            .animation(.easeInOut(duration: 0.30), value: appearance)
        }
    }

    private func findFirst(_ root: Node, where predicate: (Node) -> Bool) -> Node? {
        if predicate(root) { return root }
        for child in root.children {
            if let hit = findFirst(child, where: predicate) { return hit }
        }
        return nil
    }

    @Test("ListRow selected fill cross-fades on appearance toggle")
    func listRowCrossFade() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = ListHarness()
            graph.install(root: h)

            let darkSelection = Theme.defaultDark.colors.selection
            let lightSelection = Theme.defaultLight.colors.selection
            let node = findFirst(tree.root!) { $0.backgroundColor == darkSelection }
            #expect(node != nil)

            h.$appearance.wrappedValue = .light
            recomp.commitAll()
            #expect(scheduler.activeCount >= 1)
            #expect(node?.backgroundColor == darkSelection)

            scheduler.tick(deltaTime: 0.04)
            let mid = node?.backgroundColor
            #expect(mid != darkSelection)
            #expect(mid != lightSelection)

            scheduler.tick(deltaTime: 0.04)
            #expect(node?.backgroundColor == lightSelection)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("TreeRow selected fill cross-fades on appearance toggle")
    func treeRowCrossFade() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = TreeHarness()
            graph.install(root: h)

            let darkSelection = Theme.defaultDark.colors.selection
            let lightSelection = Theme.defaultLight.colors.selection
            let node = findFirst(tree.root!) { $0.backgroundColor == darkSelection }
            #expect(node != nil)

            h.$appearance.wrappedValue = .light
            recomp.commitAll()
            #expect(scheduler.activeCount >= 1)
            #expect(node?.backgroundColor == darkSelection)

            scheduler.tick(deltaTime: 0.04)
            let mid = node?.backgroundColor
            #expect(mid != darkSelection)
            #expect(mid != lightSelection)

            scheduler.tick(deltaTime: 0.04)
            #expect(node?.backgroundColor == lightSelection)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("TextField chrome transitions on appearance toggle")
    func textFieldCrossFade() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = TextFieldHarness()
            graph.install(root: h)

            let surface = findFirst(tree.root!) {
                ($0.attachments[TextField.surfaceMarkerKey] as? Bool) == true
            }
            #expect(surface != nil)
            let initialBorder = surface?.borderColor

            h.$appearance.wrappedValue = .light
            recomp.commitAll()
            #expect(scheduler.activeCount >= 1)

            scheduler.tick(deltaTime: 0.04)
            let updatedSurface = findFirst(tree.root!) {
                ($0.attachments[TextField.surfaceMarkerKey] as? Bool) == true
            }
            let updatedBorder = updatedSurface?.borderColor
            #expect(updatedBorder != nil)
            if let initialBorder {
                #expect(updatedBorder != initialBorder)
            }
        }
    } }

    @Test("Tab bar chrome cross-fades on appearance toggle")
    func tabCrossFade() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = TabHarness()
            graph.install(root: h)

            let darkSurfaceVariant = Theme.defaultDark.colors.surfaceVariant
            let lightSurfaceVariant = Theme.defaultLight.colors.surfaceVariant
            let node = findFirst(tree.root!) { $0.backgroundColor == darkSurfaceVariant }
            #expect(node != nil)

            h.$appearance.wrappedValue = .light
            recomp.commitAll()
            #expect(scheduler.activeCount >= 1)
            #expect(node?.backgroundColor == darkSurfaceVariant)

            scheduler.tick(deltaTime: 0.15)
            let mid = node?.backgroundColor
            #expect(mid != darkSurfaceVariant)
            #expect(mid != lightSurfaceVariant)

            scheduler.tick(deltaTime: 0.15)
            #expect(node?.backgroundColor == lightSurfaceVariant)
            #expect(scheduler.activeCount == 0)
        }
    } }
}
