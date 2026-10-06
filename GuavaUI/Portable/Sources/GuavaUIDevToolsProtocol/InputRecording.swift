import Foundation
import GuavaPlatformCore

public struct RecordedInput: Codable, Sendable {
    public var milliseconds: Double
    public var event: InputEvent
    public init(milliseconds: Double, event: InputEvent) { self.milliseconds = milliseconds; self.event = event }
}

public struct InputRecording: Codable, Sendable {
    public var version: Int = 1
    public var initialState: [String: String]
    public var focusTarget: String?
    public var events: [RecordedInput]
    public var truncated: Bool = false
    public init(initialState: [String: String], focusTarget: String? = nil, events: [RecordedInput] = []) {
        self.initialState = initialState; self.focusTarget = focusTarget; self.events = events
    }
    public var isValid: Bool {
        guard version == 1, events.count <= InputRecorder.limit,
              initialState.count <= 256, initialState.allSatisfy({ $0.key.utf8.count <= 1024 && $0.value.utf8.count <= 32768 }),
              (focusTarget?.utf8.count ?? 0) <= 1024 else { return false }
        var last = 0.0
        for input in events {
            guard input.milliseconds.isFinite, input.milliseconds >= last, input.milliseconds <= 86_400_000,
                  input.event.isRecordable else { return false }
            last = input.milliseconds
        }
        guard let bytes = try? JSONEncoder().encode(self), bytes.count <= InputRecorder.byteLimit else { return false }
        return true
    }
}

/// Scene-thread recorder with a bounded event buffer. Replays restore the
/// checkpoint and deliver events in order; timestamps are diagnostic metadata.
public final class InputRecorder {
    public static let limit = 4096
    public static let byteLimit = 768 * 1024
    private var recording: InputRecording?
    private var startedAt = 0.0
    private var byteCount = 0
    public var isRecording: Bool { recording != nil }
    public init() {}
    public func start(state: [String: String], focusTarget: String? = nil) {
        recording = InputRecording(initialState: state, focusTarget: focusTarget)
        byteCount = (try? JSONEncoder().encode(recording!).count) ?? Self.byteLimit
        startedAt = Date().timeIntervalSince1970
    }
    public func record(_ event: InputEvent) {
        guard recording != nil, event.isRecordable else { return }
        guard recording!.events.count < Self.limit else { recording!.truncated = true; return }
        let elapsed = max(recording!.events.last?.milliseconds ?? 0, max(0, Date().timeIntervalSince1970 - startedAt) * 1000)
        let input = RecordedInput(milliseconds: elapsed, event: event)
        guard let size = try? JSONEncoder().encode(input).count, byteCount + size + 1 <= Self.byteLimit else {
            recording!.truncated = true; return
        }
        byteCount += size + 1
        recording!.events.append(input)
    }
    public func stop() -> InputRecording? { defer { recording = nil }; return recording }
}

private extension InputEvent {
    var isRecordable: Bool {
        switch self {
        case .mouseButtonDown(let e), .mouseButtonUp(let e): return e.x.isFinite && e.y.isFinite
        case .mouseMotion(let e): return [e.x, e.y, e.deltaX, e.deltaY].allSatisfy(\.isFinite)
        case .mouseWheel(let e): return [e.x, e.y, e.mouseX ?? 0, e.mouseY ?? 0].allSatisfy(\.isFinite)
        case .keyDown, .keyUp: return true
        case .textInput(let text): return text.utf8.count <= 32768
        case .textEditing(let e): return e.text.utf8.count <= 32768 && e.start >= 0 && e.length >= 0
        default: return false
        }
    }
}
