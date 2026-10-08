// NativeRHI — backend factory.
//
// Maps a selected GraphicsAPI to its concrete backend. Backends that are not
// compiled for the current platform throw an honest unsupported error rather
// than being referenced as missing symbols.

enum BackendFactory {
    static func makeBackend(_ api: GraphicsAPI, config: DeviceConfig) throws -> RHIBackend {
        switch api {
        case .metal:
            #if os(macOS)
            return try MetalBackend.make(config: config)
            #else
            throw RHIError.unsupportedBackend("Metal is only available on Apple platforms")
            #endif

        case .vulkan:
            #if canImport(CVulkanHeaders)
            return try VulkanBackend.make(config: config)
            #else
            throw RHIError.unsupportedBackend("Vulkan loader integration is not built for this host")
            #endif

        case .dx12:
            #if os(Windows)
            return try DX12Backend.make(config: config)
            #else
            throw RHIError.unsupportedBackend("DirectX 12 is only available on Windows")
            #endif
        }
    }
}
