import Foundation
import GuavaUIDevToolsProtocol

/// Host adapters configure only the diagnostics they implement before starting the server.
public struct DevToolsHost {
    public struct Scene {
        public var inspect: (@MainActor (DevToolsEnvelope) -> DevToolsEnvelope)? = nil
        public var reset: (@MainActor () -> Void)? = nil
        public var snapshot: SceneSnapshotProvider? = nil
        public var select: NodeSelectionHandler? = nil
        public var clearSelection: NodeSelectionClearHandler? = nil
        public var diagnostics: (@MainActor (DevToolsEnvelope) -> DevToolsEnvelope)? = nil
        public init() {}
    }
    public var scene = Scene()
    public struct Checkpoint {
        public var restore: (@MainActor ([String: String]) -> Bool)? = nil
        public var capture: (@MainActor () -> [String: String])? = nil
        public init() {}
    }
    public var checkpoint = Checkpoint()
    public struct Recording {
        public var start: (@MainActor () -> Bool)? = nil
        public var stop: (@MainActor () -> InputRecording?)? = nil
        public var replay: (@MainActor (InputRecording) -> Bool)? = nil
        public init() {}
    }
    public var recording = Recording()
    public struct Observation {
        public var state: (@MainActor ([String]) -> StateObservationPayload)? = nil
        public var timeline: (@MainActor (UInt64) -> TimelineSnapshotPayload)? = nil
        public var capture: (@MainActor (Bool) -> Void)? = nil
        public init() {}
    }
    public var observation = Observation()
    public struct Mirror {
        public var start: (@MainActor (MirrorStartPayload) -> Void)? = nil
        public var stop: (@MainActor () -> Void)? = nil
        public var input: (@MainActor (MirrorInputPayload) -> Void)? = nil
        /// Returns nil on success, or the reason the action could not run.
        public var activate: (@MainActor (MirrorActivatePayload) -> String?)? = nil
        public init() {}
    }
    public var mirror = Mirror()
    public var execute: HostMainExecutor? = nil
    public init() {}
}
