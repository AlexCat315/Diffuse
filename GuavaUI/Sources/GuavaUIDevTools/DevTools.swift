import GuavaUIDevToolsProtocol
import GuavaUIDevToolsScene
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
    public var stateRegistry: StateRegistry? {
        didSet {
            server.stateObservationProvider = stateRegistry.map { registry in { @MainActor ids in registry.observation(ids: ids) } }
        }
    }

    private let timeline: PerformanceTimeline
    private var frameTap: FrameTap?
    private let frameTapSink = FrameTap.Sink()

    /// Closure invoked when the client sends a `mirror.input` event; the
    /// host should forward the result to its platform window session.
    public var inputDelivery: ((InputEvent) -> Void)?

    /// Captures application state when DevTools requests a checkpoint.
    /// The dictionary is opaque to DevTools; the host owns its schema.
    public var stateCheckpointProvider: (() -> [String: String])?

    /// Restores application state from a previously-captured checkpoint.
    public var inputRecordingStart: (() -> Bool)?
    public var inputRecordingStop: (() -> InputRecording?)?
    public var inputReplay: ((InputRecording) -> Bool)?

    public var stateRestoreResultHandler: (([String: String]) -> Bool)?
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
        self.timeline = tree.timeline
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
        server.inspectionHandler = { @MainActor request in scene.editor.handle(request) }
        server.inspectionResetHandler = { @MainActor in scene.editor.reset() }
        scene.editor.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.onSelectionChanged?()
                self?.notifyTreeChanged()
            }
        }

        wireMirror()
        wireState()
        server.timelineProvider = { @MainActor [weak tree] after in tree?.timeline.snapshot(after: after) ?? TimelineSnapshotPayload(events: []) }
        server.timelineCaptureHandler = { @MainActor [weak tree] in tree?.timeline.setEnabled($0) }
    }

    public func start() throws {
        guard config.enabled else { return }
        var capabilities = ["tree", "select", "log", "timing", "inspect", "style", "source", "recomposition", "timeline"]
        if stateRegistry != nil { capabilities.append("state.observe") }
        if frameTap != nil { capabilities.append("mirror") }
        if stateCheckpointProvider != nil, stateRestoreHandler != nil || stateRestoreResultHandler != nil {
            capabilities.append("state")
        }
        if inputRecordingStart != nil, inputRecordingStop != nil, inputReplay != nil {
            capabilities.append("recording")
        }
        server.advertisedCapabilities = capabilities
        wireSinks()
        do {
            try server.start()
        } catch {
            unwireSinks()
            throw error
        }
    }

    public func stop() {
        timeline.setEnabled(false)
        frameTap?.stop()
        server.stop()
        scene.editor.reset()
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
        guard FrameTap.isSupported else { return }
        frameTap = FrameTap(sink: frameTapSink, backend: backend, renderer: renderer)
    }

    /// Hosts may provide an owned pixel capture using their selected renderer.
    public func attachFrameTap(capture: @escaping FrameTap.Capture, reset: @escaping () -> Void = {}) {
        guard FrameTap.isSupported else { return }
        frameTap = FrameTap(sink: frameTapSink, capture: capture, reset: reset)
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
        server.broadcastObservations()
    }
    public func notifyFrameFinished() { server.broadcastObservations() }

    /// id of the most recently selected node, for hosts that want to
    /// draw an overlay. The host is expected to drive the actual highlight.
    public var selectedNodeID: String? { scene.editor.selectedNode.map { String($0.id.rawValue) } }

    /// Window-space frame for the selected node, if it still exists.
    public var selectedNodeAbsoluteFrame: CGRect? {
        guard let selectedNodeID,
              let node = scene.find(id: selectedNodeID) else {
            return nil
        }
        return node.absoluteFrame
    }

    private func handleSelection(id: String?) {
        scene.editor.select(id)
    }

    public func interceptInput(_ event: InputEvent) -> Bool { scene.editor.intercept(event) }
    public func drawInspectionOverlay(into list: DrawList) { scene.editor.drawOverlay(into: list) }

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
        server.stateRestoreResultHandler = { @MainActor [weak self] values in
            guard let self else { return false }
            if let restore = self.stateRestoreResultHandler { return restore(values) }
            self.stateRestoreHandler?(values); return true
        }
        server.recordingStartHandler = { @MainActor [weak self] in self?.inputRecordingStart?() ?? false }
        server.recordingStopHandler = { @MainActor [weak self] in self?.inputRecordingStop?() }
        server.recordingReplayHandler = { @MainActor [weak self] recording in self?.inputReplay?(recording) ?? false }
        server.stateCheckpointHandler = { @MainActor [weak self] in
            self?.stateCheckpointProvider?() ?? [:]
        }
        server.stateRestoreHandler = { @MainActor [weak self] payload in
            self?.stateRestoreHandler?(payload)
        }
    }
}
