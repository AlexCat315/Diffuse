import Testing
import Foundation
import GuavaUIRuntime
@testable import GuavaUICompose

private struct _ValueProbe: _PrimitiveView {
    let id: String
    let value: String

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["probe.\(id)"] = value
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) {}
}

private enum TestTheme: String, AppStorageConvertible {
    case dark, light
}

@Suite("AppStorage", .serialized)
struct AppStorageTests: GuavaUIComposeSerializedSuite {

    private func withStore(_ body: (MemoryAppStorageStore) -> Void) {
        let previous = AppStorageDefaults.store
        let store = MemoryAppStorageStore()
        AppStorageDefaults.store = store
        defer { AppStorageDefaults.store = previous }
        body(store)
    }

    private func probeValue(_ id: String, in node: Node?) -> String? {
        guard let node else { return nil }
        if let value = node.attachments["probe.\(id)"] as? String { return value }
        for child in node.children {
            if let match = probeValue(id, in: child) { return match }
        }
        return nil
    }

    @Test("FileAppStorageStore round-trips values across instances")
    func fileStoreRoundTrip() { GlobalTestLock.locked {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-appstorage-test-\(UUID().uuidString)")
            .appendingPathComponent("app-storage.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FileAppStorageStore(url: url)
        store.set(.string("light"), forKey: "theme")
        store.set(.bool(true), forKey: "grid")
        store.set(.int(42), forKey: "count")
        store.set(.double(0.5), forKey: "scale")

        let reloaded = FileAppStorageStore(url: url)
        #expect(reloaded.value(forKey: "theme") == .string("light"))
        #expect(reloaded.value(forKey: "grid") == .bool(true))
        #expect(reloaded.value(forKey: "count") == .int(42))
        #expect(reloaded.value(forKey: "scale") == .double(0.5))
        #expect(reloaded.value(forKey: "missing") == nil)
    } }

    @Test("RawRepresentable enums persist through their raw value")
    func enumSupport() { GlobalTestLock.locked {
        withStore { store in
            let theme = AppStorage(wrappedValue: TestTheme.dark, "test.enum.theme")
            #expect(theme.wrappedValue == .dark)
            theme.wrappedValue = .light
            #expect(store.values["test.enum.theme"] == .string("light"))

            // A second wrapper over the same key sees the live value.
            let again = AppStorage(wrappedValue: TestTheme.dark, "test.enum.theme")
            #expect(again.wrappedValue == .light)
        }
    } }

    private struct ProbeHarness: View {
        @AppStorage("test.view.theme") var theme = "dark"

        var body: some View {
            _ValueProbe(id: "theme", value: theme)
        }
    }

    @Test("Writing a key recomposes views that read it and persists the value")
    func writeRecomposesAndPersists() { GlobalTestLock.locked {
        withStore { store in
            let tree = NodeTree()
            let recomposer = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomposer)
            graph.install(root: ProbeHarness())
            #expect(probeValue("theme", in: tree.root) == "dark")

            // External handle on the same key (e.g. another panel or a menu).
            AppStorage(wrappedValue: "dark", "test.view.theme").wrappedValue = "light"
            while recomposer.commitAll() {}

            #expect(probeValue("theme", in: tree.root) == "light")
            #expect(store.values["test.view.theme"] == .string("light"))

            // Writing the same value again must not schedule churn.
            AppStorage(wrappedValue: "dark", "test.view.theme").wrappedValue = "light"
            #expect(recomposer.hasPending == false)
        }
    } }

    private struct RebuildHarness: View {
        @State var tick = 0
        var body: some View {
            let _ = tick
            ProbeHarness()
        }
    }

    @Test("Subscription survives parent rebuilds (replaceView path)")
    func survivesParentRebuild() { GlobalTestLock.locked {
        withStore { _ in
            let tree = NodeTree()
            let recomposer = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomposer)
            let root = RebuildHarness()
            graph.install(root: root)

            for _ in 0..<5 {
                root.$tick.wrappedValue += 1
                while recomposer.commitAll() {}
            }

            AppStorage(wrappedValue: "dark", "test.view.theme").wrappedValue = "light"
            while recomposer.commitAll() {}
            #expect(probeValue("theme", in: tree.root) == "light")
        }
    } }

    private struct TwinHarness: View {
        var body: some View {
            Column {
                ProbeHarness()
                SecondReader()
            }
        }
    }

    private struct SecondReader: View {
        @AppStorage("test.view.theme") var theme = "dark"
        var body: some View {
            _ValueProbe(id: "theme2", value: theme)
        }
    }

    @Test("Two views on the same key stay in sync")
    func crossViewSync() { GlobalTestLock.locked {
        withStore { _ in
            let tree = NodeTree()
            let recomposer = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomposer)
            graph.install(root: TwinHarness())

            AppStorage(wrappedValue: "dark", "test.view.theme").wrappedValue = "light"
            while recomposer.commitAll() {}

            #expect(probeValue("theme", in: tree.root) == "light")
            #expect(probeValue("theme2", in: tree.root) == "light")
        }
    } }
}
