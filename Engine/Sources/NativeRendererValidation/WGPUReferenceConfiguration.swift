import Foundation
import RHIWGPU

/// Keeps reference probes on a native API for the host, including Metal on macOS.
enum WGPUReferenceConfiguration {
    static var preference: WGPUBackendPreference {
        #if os(macOS)
        return .metal
        #elseif os(Windows)
        return .d3d12
        #else
        return .vulkan
        #endif
    }
    static var name: String { "wgpu-\(preference.rawValue)" }
    static func make(validation: Bool) throws -> WGPUBackend {
        if let override = ProcessInfo.processInfo.environment["GUAVA_WGPU_BACKEND"], override.lowercased() != preference.rawValue {
            throw WGPUBackendError.initFailed("reference comparison requires \(preference.rawValue) on this platform")
        }
        let backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: validation,
            framesInFlight: 3, preferredBackends: [preference]))
        try backend.initialize()
        return backend
    }
}
