// NativeRHI Metal backend — compiled MTLLibrary cache.
//
// MSL source is compiled at most once per unique source; precompiled
// `.metallib` data is loaded once per unique blob. Shader modules then look up
// their `MTLFunction` from the cached library, so the hot path never calls
// `newLibraryWithSource`.

#if os(macOS)
import Metal

final class MetalLibraryCache {
    private let device: MTLDevice
    /// MSL-source libraries keyed by the raw source bytes.
    private var sourceLibraries: [Data: MTLLibrary] = [:]
    /// metallib blobs keyed by the raw library data.
    private var metallibLibraries: [Data: MTLLibrary] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// Returns the compiled/loaded library for a shader module descriptor,
    /// compiling MSL source only on first sight of that source.
    func library(for descriptor: ShaderModuleDescriptor) throws -> MTLLibrary {
        switch descriptor.format {
        case .mslSource:
            if let cached = sourceLibraries[descriptor.code] { return cached }
            let source = String(decoding: descriptor.code, as: UTF8.self)
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                sourceLibraries[descriptor.code] = library
                return library
            } catch {
                throw RHIError.invalidArgument("MSL compile failed: \(error.localizedDescription)")
            }

        case .metallib:
            if let cached = metallibLibraries[descriptor.code] { return cached }
            do {
                // MTLDevice.makeLibrary(data:) consumes a DispatchData.
                let dispatchData = descriptor.code.withUnsafeBytes { raw -> DispatchData in
                    DispatchData(bytes: raw)
                }
                let library = try device.makeLibrary(data: dispatchData)
                metallibLibraries[descriptor.code] = library
                return library
            } catch {
                throw RHIError.invalidArgument("metallib load failed: \(error.localizedDescription)")
            }

        case .spirv, .dxil:
            throw RHIError.unsupportedFeature("Metal backend does not import SPIR-V/DXIL shaders")
        }
    }
}

#endif
