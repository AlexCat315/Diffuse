import Foundation

public enum PluginHostMethod: String, Codable, Sendable {
    case handshake
    case validatePackage = "validate_package"
    case load
    case discover
    case prepare
    case unload
}

public struct PluginHostRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var method: PluginHostMethod
    public var pluginPath: String?
    public var capabilityID: String?
    public var input: Data?
    public var querySnapshot: PluginQuerySnapshot?
    public var authorization: PluginAuthorizationRecord?

    public init(id: UUID = UUID(),
                method: PluginHostMethod,
                pluginPath: String? = nil,
                capabilityID: String? = nil,
                input: Data? = nil,
                querySnapshot: PluginQuerySnapshot? = nil,
                authorization: PluginAuthorizationRecord? = nil) {
        self.id = id
        self.method = method
        self.pluginPath = pluginPath
        self.capabilityID = capabilityID
        self.input = input
        self.querySnapshot = querySnapshot
        self.authorization = authorization
    }
}

public enum PluginQuerySnapshotError: Error, Sendable, Equatable, CustomStringConvertible {
    case totalPayloadTooLarge
    case missingPayload(PluginImportPermission)
    case invalidJSON(PluginImportPermission)
    case invalidRequest
    case importNotGranted(String)

    public var description: String {
        switch self {
        case .totalPayloadTooLarge:
            return "plugin query snapshot exceeds 512 KiB"
        case let .missingPayload(permission):
            return "plugin query snapshot is missing \(permission.rawValue)"
        case let .invalidJSON(permission):
            return "plugin query snapshot contains invalid JSON for \(permission.rawValue)"
        case .invalidRequest:
            return "plugin query request must be exactly {\"operation\":\"snapshot\"}"
        case let .importNotGranted(name):
            return "plugin attempted to query an ungranted import: \(name)"
        }
    }
}

/// Immutable, revision-bound query data supplied by the Editor for one plugin
/// preparation call. The PluginHost never receives SceneRuntime or project
/// service objects; Component imports can only retrieve one of these bounded
/// JSON snapshots.
public struct PluginQuerySnapshot: Codable, Sendable, Equatable {
    public static let maximumTotalPayloadBytes = 512 * 1_024
    public static let maximumRequestBytes = 16 * 1_024

    public var id: UUID
    public var sceneRevision: UInt64
    public var scene: Data?
    public var selection: Data?
    public var assetMetadata: Data?

    public init(id: UUID = UUID(),
                sceneRevision: UInt64,
                scene: Data? = nil,
                selection: Data? = nil,
                assetMetadata: Data? = nil) {
        self.id = id
        self.sceneRevision = sceneRevision
        self.scene = scene
        self.selection = selection
        self.assetMetadata = assetMetadata
    }

    public func validate(for grantedImports: Set<PluginImportPermission>) throws {
        let payloads = [scene, selection, assetMetadata].compactMap { $0 }
        let total = payloads.reduce(0) { partial, payload in
            let (sum, overflow) = partial.addingReportingOverflow(payload.count)
            return overflow ? Int.max : sum
        }
        guard total <= Self.maximumTotalPayloadBytes else {
            throw PluginQuerySnapshotError.totalPayloadTooLarge
        }
        for permission in grantedImports {
            guard let payload = payload(for: permission) else {
                throw PluginQuerySnapshotError.missingPayload(permission)
            }
            guard let value = try? JSONSerialization.jsonObject(with: payload),
                  value is [String: Any] || value is [Any] else {
                throw PluginQuerySnapshotError.invalidJSON(permission)
            }
        }
    }

    public func response(importName: String,
                         request: Data,
                         grantedImports: Set<PluginImportPermission>) throws -> Data {
        guard request.count <= Self.maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              object.count == 1,
              object["operation"] as? String == "snapshot" else {
            throw PluginQuerySnapshotError.invalidRequest
        }
        guard let permission = PluginImportPermission(rawValue: importName),
              grantedImports.contains(permission) else {
            throw PluginQuerySnapshotError.importNotGranted(importName)
        }
        guard let payload = payload(for: permission) else {
            throw PluginQuerySnapshotError.missingPayload(permission)
        }
        return payload
    }

    public func payload(for permission: PluginImportPermission) -> Data? {
        switch permission {
        case .sceneQuery: return scene
        case .selectionQuery: return selection
        case .assetMetadataQuery: return assetMetadata
        }
    }
}

public struct PluginHostResponse: Codable, Sendable, Equatable {
    public var id: UUID
    public var ok: Bool
    public var payload: Data?
    public var error: String?

    public init(id: UUID, ok: Bool, payload: Data? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

public enum PluginHostFrameError: Error, Sendable, Equatable {
    case frameTooLarge
    case incompleteFrame
    case trailingBytes
}

/// Four-byte big-endian length prefix followed by one JSON payload.
public enum PluginHostFrameCodec {
    public static let maximumFrameBytes = 1_024 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumFrameBytes else { throw PluginHostFrameError.frameTooLarge }
        let length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count >= 4 else { throw PluginHostFrameError.incompleteFrame }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maximumFrameBytes else { throw PluginHostFrameError.frameTooLarge }
        let expected = 4 + Int(length)
        guard frame.count >= expected else { throw PluginHostFrameError.incompleteFrame }
        guard frame.count == expected else { throw PluginHostFrameError.trailingBytes }
        return try JSONDecoder().decode(type, from: frame.subdata(in: 4..<expected))
    }
}

/// Adapter seam for the pinned Wasmtime v45 Component runtime. Implementations
/// must configure fuel, memory limits, epoch interruption, and no ambient WASI.
public protocol WASIComponentRuntime: Sendable {
    var runtimeVersion: String { get }
    func validateComponent(_ package: ValidatedPluginPackage,
                           limits: PluginResourceLimits) throws
    /// Returns only `{\"capability_ids\":[...]}`. Capability metadata and
    /// schemas are derived independently from the validated WIT package.
    func discover(_ package: ValidatedPluginPackage,
                  limits: PluginResourceLimits) throws -> Data
    func prepare(_ package: ValidatedPluginPackage,
                 capabilityID: String,
                 input: Data,
                 querySnapshot: PluginQuerySnapshot?,
                 limits: PluginResourceLimits) throws -> Data
    func interrupt(pluginID: String)
}

public enum PluginRuntimeUnavailableError: Error, CustomStringConvertible {
    case unavailable

    public var description: String {
        "Wasmtime 45.0.0 Component runtime is not linked; plugin execution is fail-closed"
    }
}

/// Used on builds that do not carry the pinned Wasmtime artifact. Package
/// validation remains available, but component code can never execute.
public struct FailClosedWASIComponentRuntime: WASIComponentRuntime {
    public let runtimeVersion = "unavailable"
    public init() {}
    public func validateComponent(_ package: ValidatedPluginPackage,
                                  limits: PluginResourceLimits) throws { throw PluginRuntimeUnavailableError.unavailable }
    public func discover(_ package: ValidatedPluginPackage,
                         limits: PluginResourceLimits) throws -> Data { throw PluginRuntimeUnavailableError.unavailable }
    public func prepare(_ package: ValidatedPluginPackage,
                        capabilityID: String,
                        input: Data,
                        querySnapshot: PluginQuerySnapshot?,
                        limits: PluginResourceLimits) throws -> Data { throw PluginRuntimeUnavailableError.unavailable }
    public func interrupt(pluginID: String) {}
}
