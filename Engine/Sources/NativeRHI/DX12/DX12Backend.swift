// NativeRHI DX12 backend entry.
//
// DirectX 12 is only available on Windows. The concrete device is compiled only
// under `#if os(Windows)`; on every other host this throws so it never affects
// the macOS build.

public enum DX12Backend {
    public static func make(config: DeviceConfig) throws -> RHIBackend {
        #if os(Windows)
        return try DX12Device.make(config: config)
        #else
        throw RHIError.unsupportedBackend("DirectX 12 is only available on Windows")
        #endif
    }
}
