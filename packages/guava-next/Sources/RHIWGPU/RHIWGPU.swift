import CWGPUBridge
import Foundation

public enum WGPUBackendState: Sendable {
    case uninitialized
    case bridgeReady
    case instanceReady
}

public struct WGPUDeviceConfig: Sendable {
    public var validationEnabled: Bool
    public var framesInFlight: UInt32
    public var libraryPath: String?

    public init(validationEnabled: Bool = true, framesInFlight: UInt32 = 2, libraryPath: String? = nil) {
        self.validationEnabled = validationEnabled
        self.framesInFlight = framesInFlight
        self.libraryPath = libraryPath
    }
}

public enum WGPUBackendError: Error {
    case bridgeInitializeFailed(String)
    case createInstanceFailed(String)
    case releaseInstanceFailed(String)
}

public final class WGPUBackend {
    public private(set) var state: WGPUBackendState = .uninitialized
    public private(set) var config: WGPUDeviceConfig
    private var instance: UnsafeMutableRawPointer?

    public init(config: WGPUDeviceConfig = .init()) {
        self.config = config
    }

    deinit {
        do {
            try shutdown()
        } catch {
            // Ignore errors during deinit; process is shutting down.
        }
    }

    public func initialize() throws {
        if state != .uninitialized {
            return
        }

        let ok: Int32
        if let path = config.libraryPath {
            ok = path.withCString { cPath in
                wgpu_bridge_initialize(cPath)
            }
        } else {
            ok = wgpu_bridge_initialize(nil)
        }
        guard ok == 1 else {
            throw WGPUBackendError.bridgeInitializeFailed(lastBridgeError())
        }
        state = .bridgeReady

        var out: UnsafeMutableRawPointer?
        let createOk = wgpu_bridge_create_instance(&out)
        guard createOk == 1, let out else {
            throw WGPUBackendError.createInstanceFailed(lastBridgeError())
        }

        instance = out
        state = .instanceReady
    }

    public func shutdown() throws {
        if let instance {
            let ok = wgpu_bridge_release_instance(instance)
            guard ok == 1 else {
                throw WGPUBackendError.releaseInstanceFailed(lastBridgeError())
            }
            self.instance = nil
        }

        wgpu_bridge_shutdown()
        state = .uninitialized
    }

    private func lastBridgeError() -> String {
        guard let ptr = wgpu_bridge_last_error() else {
            return "unknown bridge error"
        }
        return String(cString: ptr)
    }
}
