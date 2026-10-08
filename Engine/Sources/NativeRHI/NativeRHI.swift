// NativeRHI — module namespace and top-level factory.
//
// `NativeRHI` is an caseless enum used as a namespace for module-wide constants
// and the platform backend selection used by `DeviceConfig` defaults. The
// actual `Device` lives in Device.swift.

import Foundation

public enum NativeRHI {
    /// Semantic version of the Swift RHI port.
    public static let version = "0.1.0"

    /// Backend preference order for the current platform. The first backend
    /// that constructs successfully wins; later entries are fallbacks.
    public static var platformDefaultBackends: [GraphicsAPI] {
        #if os(macOS)
        return [.metal, .vulkan]
        #elseif os(Windows)
        return [.dx12, .vulkan]
        #else
        return [.vulkan]
        #endif
    }

    /// True when a backend is part of the current build. Backends that are
    /// source-only on the host (e.g. DX12 on macOS) are reported unavailable.
    public static func isCompiledIn(_ api: GraphicsAPI) -> Bool {
        switch api {
        case .metal:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        case .vulkan:
            #if canImport(CVulkanHeaders)
            return VulkanBackend.isAvailable
            #else
            return false
            #endif
        case .dx12:
            #if os(Windows)
            return true
            #else
            return false
            #endif
        }
    }
}
