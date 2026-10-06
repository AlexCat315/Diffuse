import Foundation
import GuavaUIDevToolsProtocol
import GuavaUIDevToolsServer

/// Headless diagnostic host: exercises the real server without GPU dependencies.
@main
struct DevToolsProbe {
    @MainActor
    static func main() async throws {
        let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 9229
        let server = DevServer(config: DevToolsConfig(port: port, appTitle: "GuavaUI transport probe"))
        var state = ["count": "0"]
        server.advertisedCapabilities = ["tree", "select", "log", "timing", "state"]
        server.snapshotProvider = {
            TreeSnapshotPayload(root: NodeSummary(
                id: "1", viewTag: "TransportProbe", debugName: "headless.root",
                frame: NodeFrame(x: 0, y: 0, w: 320, h: 180),
                flags: NodeFlags(hitTestable: true, focusable: false, clipsToBounds: false,
                                 hasBackground: true, hasBorder: false),
                children: [], elementID: "1"))
        }
        server.stateCheckpointHandler = { state }
        server.stateRestoreHandler = { state = $0 }
        try server.start()
        defer { server.stop() }
        print("DevTools probe: ws://127.0.0.1:\(server.boundPort!)/")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
    }
}
