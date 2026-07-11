import Foundation
import Logging
import RHIWGPU
import GuavaUIRuntime
import EngineKernel

/// One-stop entry for hosts that want to enable DevTools. Wires the
/// SceneInspector into a DevServer and exposes a single `start` /
/// `stop` pair plus a `notifyTreeChanged()` hook for AppRuntime.
@MainActor
public final class DevTools {

    public let config: DevToolsConfig
    public let server: DevServer
    public let scene: SceneInspector

    /// Sink for log records. Install with
    /// `LoggingSystem.bootstrap { LogTap(label: $0, sink: tools.logSink) }`
    /// from the host before any `Logger` is constructed.
    public let logSink: LogTap.Sink

    /// Frame timing publisher; the host calls `record(...)` once per frame.
    public let timing = TimingPublisher()

    private var frameTap: FrameTap?
    private let frameTapSink = FrameTap.Sink()

    /// Closure invoked when the client sends a `mirror.input` event; the
    /// host should forward the result to its platform window session.
    public var inputDelivery: ((InputEvent) -> Void)?

    /// Captures application state when DevTools requests a checkpoint.
    /// The dictionary is opaque to DevTools; the host owns its schema.
    public var stateCheckpointProvider: (() -> [String: String])?

    /// Restores application state from a previously-captured checkpoint.
    public var stateRestoreHandler: (([String: String]) -> Void)?

    /// `true` between `mirror.start` and `mirror.stop`. AppRuntime can poll
    /// this to keep requesting redisplay so the mirror stays live even when
    /// the host UI itself isn't dirty.
    public var mirrorIsActive: Bool { frameTap?.isActive ?? false }

    /// Invoked on the main actor immediately after `mirror.start` wires up
    /// the FrameTap. Hosts using a demand-render loop (e.g. SDL3) must call
    /// `requestDisplay()` here so the first mirror frame can be produced.
    public var onMirrorStart: (@MainActor () -> Void)?

    /// Invoked when a remote client selects a node. Hosts can redraw a
    /// diagnostic overlay without mutating the normal UI tree.
    public var onSelectionChanged: (@MainActor () -> Void)?

    public init(config: DevToolsConfig,
                tree: NodeTree,
                invalidationLog: InvalidationLog? = nil,
                renderTree: RenderTree? = nil,
                logSink: LogTap.Sink = LogTap.Sink()) {
        self.config = config
        self.server = DevServer(config: config)
        self.logSink = logSink
        self.scene = SceneInspector(tree: tree,
                                    invalidationLog: invalidationLog,
                                    renderTree: renderTree)

        let scene = self.scene
        server.snapshotProvider = { @MainActor in scene.snapshot() }
        server.selectionHandler = { @MainActor [weak self] id in
            self?.handleSelection(id: id)
        }
        server.selectionClearHandler = { @MainActor [weak self] in
            self?.handleSelection(id: nil)
        }

        wireMirror()
        wireState()
    }

    public func start() throws {
        guard config.enabled else { return }
        wireSinks()
        do {
            try server.start()
        } catch {
            unwireSinks()
            throw error
        }
    }

    public func stop() {
        frameTap?.stop()
        server.stop()
        unwireSinks()
    }

    private func unwireSinks() {
        logSink.deliver = nil
        timing.deliver = nil
        frameTapSink.deliver = nil
    }

    /// Hook the FrameTap to the host's wgpu backend + draw list renderer.
    /// Must be called after `WGPUBackend.initialize()` and before the
    /// first `mirrorCapture(...)`.
    public func attachFrameTap(backend: WGPUBackend, renderer: DrawListRenderer) {
        frameTap = FrameTap(sink: frameTapSink, backend: backend, renderer: renderer)
    }

    /// Capture a frame for the mirror viewport. No-op unless the client
    /// has issued `mirror.start` since the last `mirror.stop`.
    public func mirrorCapture(drawList: DrawList,
                              widthPx: UInt32,
                              heightPx: UInt32,
                              logical: (width: Float, height: Float)) {
        frameTap?.capture(
            drawList: drawList,
            widthPx: widthPx,
            heightPx: heightPx,
            logical: logical
        )
    }

    /// Call after layout has settled when the tree was changed. The snapshot
    /// is captured immediately on the main actor; this also works in hosts
    /// whose synchronous platform loop does not drain DispatchQueue.main.
    public func notifyTreeChanged() {
        server.broadcastTreeDelta()
    }

    /// id of the most recently selected node, for hosts that want to
    /// draw an overlay. The host is expected to drive the actual highlight.
    public private(set) var selectedNodeID: String?

    /// Window-space frame for the selected node, if it still exists.
    public var selectedNodeAbsoluteFrame: CGRect? {
        guard let selectedNodeID,
              let node = scene.find(id: selectedNodeID) else {
            return nil
        }
        return node.absoluteFrame
    }

    private func handleSelection(id: String?) {
        selectedNodeID = id.flatMap { scene.find(id: $0) == nil ? nil : $0 }
        onSelectionChanged?()
    }

    private func wireSinks() {
        // Capture the server reference rather than self. `stop()` clears all
        // callbacks so a process-wide LogTap does not retain a stopped server.
        let server = self.server
        logSink.deliver = { entry in
            server.broadcastLog(entry)
        }
        timing.deliver = { frame in
            server.broadcastTiming(frame)
        }
        frameTapSink.deliver = { frame in
            server.broadcastMirrorFrame(frame)
        }
    }

    private func wireMirror() {
        server.mirrorStartHandler = { @MainActor [weak self] payload in
            guard let self else { return }
            self.frameTap?.start(
                fps: payload.fps ?? 15,
                quality: payload.quality ?? 0.7
            )
            self.onMirrorStart?()
        }
        server.mirrorStopHandler = { @MainActor [weak self] in
            self?.frameTap?.stop()
            self?.server.broadcastMirrorStopped(reason: "client")
        }
        server.mirrorInputHandler = { @MainActor [weak self] payload in
            guard let event = InputBridge.event(from: payload) else { return }
            self?.inputDelivery?(event)
        }
    }

    private func wireState() {
        server.stateCheckpointHandler = { @MainActor [weak self] in
            self?.stateCheckpointProvider?() ?? [:]
        }
        server.stateRestoreHandler = { @MainActor [weak self] payload in
            self?.stateRestoreHandler?(payload)
        }
    }
}
