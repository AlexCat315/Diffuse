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
    public let logSink = LogTap.Sink()

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

    public init(config: DevToolsConfig,
                tree: NodeTree,
                invalidationLog: InvalidationLog? = nil,
                renderTree: RenderTree? = nil,
                inputScene: InputScene? = nil) {
        self.config = config
        self.server = DevServer(config: config)
        self.scene = SceneInspector(tree: tree,
                                    invalidationLog: invalidationLog,
                                    renderTree: renderTree,
                                    inputScene: inputScene)

        let scene = self.scene
        server.snapshotProvider = { @MainActor in scene.snapshot() }
        server.selectionHandler = { @MainActor [weak self] id in
            self?.handleSelection(id: id)
        }

        wireSinks()
        wireMirror()
        wireState()
    }

    public func start() throws {
        guard config.enabled else { return }
        try server.start()
    }

    public func stop() {
        frameTap?.stop()
        server.stop()
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

    /// Call once per host frame after layout has settled. The server
    /// debounces internally — back-to-back calls in the same frame send a
    /// single delta.
    public func notifyTreeChanged() {
        guard !pendingDelta else { return }
        pendingDelta = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDelta = false
            self.server.broadcastTreeDelta()
        }
    }

    /// id of the most recently selected node, for hosts that want to
    /// draw an overlay. The host is expected to drive the actual highlight.
    public private(set) var selectedNodeID: String?

    private var pendingDelta = false

    private func handleSelection(id: String) {
        selectedNodeID = id
    }

    private func wireSinks() {
        // The closures live for the lifetime of the process via
        // LoggingSystem.bootstrap, so capture the server reference, not
        // self, to avoid a retain cycle through DevTools.
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
