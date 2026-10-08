// NativeRHI Metal backend entry — pure Swift, no ObjC++ bridge.
//
// The concrete implementation lives in the Metal/ directory and is built by the
// Metal backend phase: real device/ray-tracing capability detection, the chunked
// upload ring, FrameRing deferred destruction, and a shader library cache.

#if os(macOS)
import Metal

public enum MetalBackend {
    /// Creates the Metal backend for the current physical device.
    public static func make(config: DeviceConfig) throws -> RHIBackend {
        try MetalDevice.make(config: config)
    }
}
#endif
