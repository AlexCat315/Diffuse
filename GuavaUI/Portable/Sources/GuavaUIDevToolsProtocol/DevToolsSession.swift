import Foundation

public enum DevToolsSubscription: String, Hashable, Sendable {
    case tree, log, timing, mirror
}

/// Transport-independent session state. Owned by the serial socket queue or
/// browser thread; never accessed from the scene thread on native hosts.
public final class DevToolsSession {
    public private(set) var subscriptions: Set<DevToolsSubscription> = []
    public init() {}
    @discardableResult public func set(_ stream: DevToolsSubscription, enabled: Bool) -> Bool {
        if enabled { return subscriptions.insert(stream).inserted }
        return subscriptions.remove(stream) != nil
    }
    public func reset() { subscriptions.removeAll() }

    /// Shared validation before either host applies a command to its scene.
    public func validate(_ request: DevToolsEnvelope) -> DevToolsEnvelope? {
        if request.type.hasPrefix("inspect.") {
            return InspectionValidation.error(request).map { Self.error(request, code: "bad_request", message: $0) }
        }
        let message: String?
        switch request.type {
        case "select.node":
            message = request.payload?.objectValue?["id"]?.stringValue == nil ? "select.node requires payload.id" : nil
        case "state.restore", "state.diff":
            message = Self.state(request.payload) == nil ? "\(request.type) requires an object with string values" : nil
        case "mirror.input":
            if !subscriptions.contains(.mirror) {
                return Self.error(request, code: "invalid_state", message: "mirror.input requires an active mirror subscription")
            }
            message = DevToolsCodec.decode(MirrorInputPayload.self, request.payload) == nil ? "mirror.input requires payload" : nil
        case "mirror.start":
            message = request.payload != nil && DevToolsCodec.decode(MirrorStartPayload.self, request.payload) == nil ? "mirror.start payload is malformed" : nil
        case "input.replay":
            message = DevToolsCodec.decode(InputRecording.self, request.payload)?.isValid != true ? "input.replay requires a valid bounded recording" : nil
        default: message = nil
        }
        return message.map { Self.error(request, code: "bad_request", message: $0) }
    }
    public static func state(_ value: JSONValue?) -> [String: String]? {
        guard let object = value?.objectValue, object.values.allSatisfy({ $0.stringValue != nil }) else { return nil }
        return object.compactMapValues(\.stringValue)
    }
    public static func ok(_ request: DevToolsEnvelope) -> DevToolsEnvelope? {
        guard let id = request.id else { return nil }
        return DevToolsEnvelope(type: request.type + ".ok", id: id)
    }
    public static func error(_ request: DevToolsEnvelope, code: String, message: String) -> DevToolsEnvelope {
        DevToolsEnvelope(type: request.type + ".err", id: request.id, payload: DevToolsCodec.json(ErrorPayload(code: code, message: message)))
    }
}

public enum DevToolsCodec {
    public static func json<T: Encodable>(_ value: T) -> JSONValue {
        // Host-produced protocol values must be finite and JSON encodable.
        try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public struct StateDifference: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public var before: String
        public var after: String
    }
    public var added: [String: String]
    public var removed: [String: String]
    public var changed: [String: Change]
    public init(before: [String: String], after: [String: String]) {
        added = after.filter { before[$0.key] == nil }
        removed = before.filter { after[$0.key] == nil }
        changed = [:]
        for (key, value) in before {
            if let next = after[key], next != value { changed[key] = Change(before: value, after: next) }
        }
    }
}
