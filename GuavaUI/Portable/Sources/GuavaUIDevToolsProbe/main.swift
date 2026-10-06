import Foundation
import GuavaUIDevToolsProtocol
import GuavaUIDevToolsServer
import GuavaUIDevToolsScene
import GuavaUIComposeCore

private struct ProbeComponent: View {
    @State var count = 0
    var body: some View { EmptyView() }
}

/// Headless diagnostic host: exercises the real server without GPU dependencies.
@main
struct DevToolsProbe {
    @MainActor
    static func main() async throws {
        let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 9229
        let server = DevServer(config: DevToolsConfig(port: port, appTitle: "GuavaUI transport probe"))
        var state = ["count": "0"]
        let tree = NodeTree()
        let root = Node(); root.viewTag = "TransportProbe"; root.attachments[LayoutDebugAttachmentKey.debugName] = "headless.root"
        root.backgroundColor = .white
        let layout = LayoutNode(); layout.width = 320; layout.height = 180; layout.setPadding(8)
        root.layoutNode = layout; tree.root = root
        let component = ProbeComponent(), componentTree = NodeTree(), recomposer = Recomposer()
        let graph = ViewGraph(tree: componentTree, recomposer: recomposer)
        graph.install(root: component)
        root.addChild(componentTree.root!)
        let inspector = SceneInspector(tree: tree)
        server.advertisedCapabilities = ["tree", "select", "log", "timing", "state", "inspect", "style", "source", "recomposition"]
        server.snapshotProvider = {
            layout.calculateLayout(availableWidth: 320, availableHeight: 180); root.frame = layout.frame
            return inspector.snapshot()
        }
        server.selectionHandler = { inspector.editor.select($0) }
        server.selectionClearHandler = { inspector.editor.select(nil) }
        server.inspectionHandler = { inspector.editor.handle($0) }
        server.inspectionResetHandler = { inspector.editor.reset() }
        inspector.editor.onChange = { [weak server] in MainActor.assumeIsolated { server?.broadcastTreeDelta() } }
        server.stateCheckpointHandler = { state }
        server.stateRestoreHandler = {
            state = $0; component.count = $0["count"].flatMap(Int.init) ?? 0
            recomposer.commitAll(); server.broadcastTreeDelta()
        }
        try server.start()
        defer { server.stop() }
        print("DevTools probe: ws://127.0.0.1:\(server.boundPort!)/")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
    }
}
