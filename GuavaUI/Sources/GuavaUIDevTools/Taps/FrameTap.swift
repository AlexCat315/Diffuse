import GuavaUIDevToolsProtocol
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Logging)
import Logging
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import RHIWGPU
import GuavaUIRuntime

/// Owned BGRA8 pixels supplied by a host renderer. Padding may follow each row.
public struct FrameTapPixels: Sendable {
    public let data: Data
    public let bytesPerRow: Int
    public init(data: Data, bytesPerRow: Int) { self.data = data; self.bytesPerRow = bytesPerRow }
}

#if canImport(ImageIO)
import ImageIO

/// Captures a copy of each rendered frame into an offscreen texture, reads it
/// back into a CPU buffer, JPEG-encodes it via ImageIO and pushes the result
/// to attached DevTools clients.
///
/// The mirror runs on the host's main thread because it shares renderer
/// bindings with the primary surface render path. To avoid
/// stalling the host every frame the tap is rate-limited (default 15fps).
@MainActor
public final class FrameTap {
    public static let isSupported = true
    public typealias Pixels = FrameTapPixels
    public typealias Capture = (DrawList, UInt32, UInt32, (width: Float, height: Float)) throws -> Pixels
    private enum CaptureSource {
        case wgpu(WGPUBackend, DrawListRenderer)
        case host(Capture, () -> Void)
    }

    public final class Sink: @unchecked Sendable {
        public init() {}
        /// Set by `DevTools` once the server is ready to forward frames.
        public var deliver: ((MirrorFramePayload) -> Void)?
    }

    /// wgpu requires `bytesPerRow` to be a multiple of this value when
    /// copying texture → buffer.
    private static let copyBytesPerRowAlignment: Int = 256

    private let sink: Sink
    private let source: CaptureSource
    private var captureRenderer: DrawListRenderer?

    private var enabled = false
    private var quality: Double = 0.7
    private var minFrameInterval: TimeInterval = 1.0 / 15.0
    private var lastCaptureAt: TimeInterval = 0

    private var seq: UInt64 = 0
    private var widthPx: UInt32 = 0
    private var heightPx: UInt32 = 0
    private var bytesPerRow: Int = 0

    private var texture: GPUTexture?
    private var textureView: GPUTextureView?
    private var readback: GPUBuffer?

    #if canImport(Logging)
    private let log = Logger(label: "guava.devtools.frameTap")
    #endif
    /// Counts consecutive capture failures to throttle warning spam.
    private var consecutiveErrors: Int = 0
    private var capturesSinceStart: Int = 0

    public init(sink: Sink, backend: WGPUBackend, renderer: DrawListRenderer) {
        self.sink = sink
        source = .wgpu(backend, renderer)
    }

    public init(sink: Sink, capture: @escaping Capture, reset: @escaping () -> Void = {}) {
        self.sink = sink
        source = .host(capture, reset)
    }

    public var isActive: Bool { enabled }

    public func start(fps: Double, quality: Double) {
        let clampedFps = max(1.0, min(60.0, fps))
        self.minFrameInterval = 1.0 / clampedFps
        self.quality = max(0.1, min(1.0, quality))
        self.enabled = true
        self.lastCaptureAt = 0
        self.consecutiveErrors = 0
        self.capturesSinceStart = 0
        #if canImport(Logging)
        log.info("mirror start fps=\(clampedFps) quality=\(self.quality)")
        #endif
    }

    public func stop() {
        enabled = false
        #if canImport(Logging)
        log.info("mirror stop after \(capturesSinceStart) captures, errors=\(consecutiveErrors)")
        #endif
        // Drop GPU resources so the next start() picks up the latest size.
        texture = nil
        textureView = nil
        readback = nil
        widthPx = 0
        heightPx = 0
        bytesPerRow = 0
        if case .host(_, let reset) = source { reset() }
    }

    /// Render the same draw list through the selected capture source and
    /// emit a `mirror.frame` to clients. Called by `AppRuntime.handleFrame`
    /// after the primary surface present.
    ///
    /// - Parameters:
    ///   - drawList: the same DrawList that drove the surface render.
    ///   - widthPx: render target width in physical pixels.
    ///   - heightPx: render target height in physical pixels.
    ///   - logical: logical (DIP) viewport size for coordinate-space mapping.
    public func capture(drawList: DrawList,
                        widthPx: UInt32,
                        heightPx: UInt32,
                        logical: (width: Float, height: Float)) {
        if !enabled {
            return
        }
        guard sink.deliver != nil else {
            if capturesSinceStart == 0, consecutiveErrors == 0 {
                #if canImport(Logging)
                log.warning("mirror enabled but sink.deliver is nil; broadcaster not wired")
                #endif
                consecutiveErrors = 1
            }
            return
        }
        guard widthPx > 0, heightPx > 0 else {
            if capturesSinceStart == 0, consecutiveErrors == 0 {
                #if canImport(Logging)
                log.warning("mirror capture skipped: zero-sized drawable \(widthPx)x\(heightPx)")
                #endif
                consecutiveErrors = 1
            }
            return
        }

        // A remote inspector does not need Retina-native pixels. Capturing at
        // logical resolution (capped for very large windows) cuts GPU readback,
        // JPEG size, WebSocket traffic, and browser decode pressure sharply.
        let targetSize = Self.targetSize(logical: logical)
        let captureWidthPx = targetSize.width
        let captureHeightPx = targetSize.height

        let now = Date().timeIntervalSince1970
        if now - lastCaptureAt < minFrameInterval { return }
        lastCaptureAt = now

        do {
            let pixels: Pixels
            switch source {
            case .wgpu(let backend, let renderer):
                pixels = try captureWGPU(backend: backend, renderer: renderer, drawList: drawList,
                    captureWidthPx: captureWidthPx, captureHeightPx: captureHeightPx, logical: logical)
            case .host(let capture, _):
                pixels = try capture(drawList, captureWidthPx, captureHeightPx, logical)
            }
            let height = Int(captureHeightPx)
            guard pixels.bytesPerRow >= Int(captureWidthPx) * 4,
                  pixels.bytesPerRow <= Int.max / height,
                  pixels.data.count >= pixels.bytesPerRow * height else {
                throw WGPUBackendError.initFailed("mirror pixel buffer is incomplete")
            }
            let jpeg = pixels.data.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { encodeJPEG(bgra: $0, width: Int(captureWidthPx), height: height,
                    bytesPerRow: pixels.bytesPerRow, quality: quality) }
            }
            guard let jpeg else { return }

            seq &+= 1
            capturesSinceStart &+= 1
            consecutiveErrors = 0
            if capturesSinceStart == 1 {
                #if canImport(Logging)
                log.debug("mirror first frame seq=\(seq) px=\(captureWidthPx)x\(captureHeightPx) jpeg=\(jpeg.count)B")
                #endif
            }
            sink.deliver?(MirrorFramePayload(
                seq: seq,
                width: Int(captureWidthPx),
                height: Int(captureHeightPx),
                logicalWidth: Double(logical.width),
                logicalHeight: Double(logical.height),
                jpegBase64: jpeg.base64EncodedString()
            ))
        } catch {
            consecutiveErrors &+= 1
            // Log the first 3 failures and every 60th after that to avoid
            // flooding the host log when wgpu is in a permanently bad state.
            if consecutiveErrors <= 3 || consecutiveErrors % 60 == 0 {
                #if canImport(Logging)
                log.warning("mirror capture failed (#\(consecutiveErrors)): \(error)")
                #endif
            }
        }
    }

    private func captureWGPU(backend: WGPUBackend, renderer: DrawListRenderer, drawList: DrawList,
        captureWidthPx: UInt32, captureHeightPx: UInt32, logical: (width: Float, height: Float)) throws -> Pixels {
        try ensureResources(backend: backend, widthPx: captureWidthPx, heightPx: captureHeightPx)
        if captureRenderer == nil {
            captureRenderer = try renderer.makeSibling(
                format: .bgra8Unorm,
                sampleCount: 1
            )
        } else if let captureRenderer {
            try captureRenderer.synchronizeTextures(from: renderer)
        }
        guard let captureRenderer, let texture, let textureView, let readback else { throw WGPUBackendError.initFailed("mirror resources unavailable") }

        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(
            colorView: textureView,
            loadOp: .clear,
            storeOp: .store,
            clearColor: .black
        )
        try captureRenderer.render(
            list: drawList,
            pass: pass,
            viewportPx: (captureWidthPx, captureHeightPx),
            coordinateSpace: (logical.width, logical.height)
        )
        pass.end()
        encoder.copyTextureToBuffer(
            source: texture,
            destination: readback,
            bufferOffset: 0,
            bytesPerRow: UInt32(bytesPerRow),
            rowsPerImage: captureHeightPx,
            width: captureWidthPx,
            height: captureHeightPx
        )
        let commandBuffer = try encoder.finish()
        backend.submit(commandBuffer)

        try backend.bufferMapSync(readback)
        defer { readback.unmap() }
        guard let mapped = readback.getMappedRange(offset: 0, size: UInt64(bytesPerRow * Int(captureHeightPx))) else {
            throw WGPUBackendError.initFailed("mirror buffer mapping unavailable")
        }

        return Pixels(data: Data(bytes: mapped, count: bytesPerRow * Int(captureHeightPx)), bytesPerRow: bytesPerRow)
    }

    // MARK: - Resources

    private func ensureResources(backend: WGPUBackend, widthPx: UInt32, heightPx: UInt32) throws {
        if texture != nil, self.widthPx == widthPx, self.heightPx == heightPx {
            return
        }
        // Recreate at the new size.
        let stride = Self.alignedRowStride(width: Int(widthPx))
        let tex = try backend.createTexture(
            width: widthPx,
            height: heightPx,
            format: .bgra8Unorm,
            usage: [.renderAttachment, .copySrc],
            mipLevels: 1,
            depthOrLayers: 1
        )
        let view = try tex.createView()
        let buf = try backend.createBuffer(
            size: UInt64(stride * Int(heightPx)),
            usage: [.mapRead, .copyDst],
            mappedAtCreation: false
        )
        self.texture = tex
        self.textureView = view
        self.readback = buf
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.bytesPerRow = stride
    }

    private static func alignedRowStride(width: Int) -> Int {
        let raw = width * 4
        let remainder = raw % copyBytesPerRowAlignment
        if remainder == 0 { return raw }
        return raw + (copyBytesPerRowAlignment - remainder)
    }

    private static func targetSize(logical: (width: Float, height: Float)) -> (width: UInt32, height: UInt32) {
        let logicalWidth = max(1, Double(logical.width))
        let logicalHeight = max(1, Double(logical.height))
        let scale = min(1, min(1_920 / logicalWidth, 1_080 / logicalHeight))
        return (
            width: UInt32(max(1, (logicalWidth * scale).rounded(.up))),
            height: UInt32(max(1, (logicalHeight * scale).rounded(.up)))
        )
    }

    // MARK: - JPEG

    private func encodeJPEG(bgra: UnsafeRawPointer,
                            width: Int,
                            height: Int,
                            bytesPerRow: Int,
                            quality: Double) -> Data? {
        let totalBytes = bytesPerRow * height
        // CGDataProvider needs ownership of a copy because the wgpu mapping
        // is unmapped synchronously after this function returns.
        let copy = Data(bytes: bgra, count: totalBytes)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }

        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue),
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
        ]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        let outData = NSMutableData()
        let typeID: CFString
        #if canImport(UniformTypeIdentifiers)
        if #available(macOS 11.0, *) {
            typeID = UTType.jpeg.identifier as CFString
        } else {
            typeID = "public.jpeg" as CFString
        }
        #else
        typeID = "public.jpeg" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithData(outData, typeID, 1, nil) else {
            return nil
        }
        let options: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }
}

#else

/// Stub FrameTap for platforms without ImageIO (Windows, Linux).
/// Frame mirroring is not supported on these platforms.
@MainActor
public final class FrameTap {
    public static let isSupported = false
    public typealias Pixels = FrameTapPixels
    public typealias Capture = (DrawList, UInt32, UInt32, (width: Float, height: Float)) throws -> Pixels
    public final class Sink: @unchecked Sendable {
        public init() {}
        public var deliver: ((MirrorFramePayload) -> Void)?
    }

    public var isActive: Bool { false }

    public init(sink: Sink, backend: WGPUBackend, renderer: DrawListRenderer) {}
    public init(sink: Sink, capture: @escaping Capture, reset: @escaping () -> Void = {}) {}
    public func start(fps: Double, quality: Double) {}
    public func stop() {}
    public func capture(drawList: DrawList,
                        widthPx: UInt32,
                        heightPx: UInt32,
                        logical: (width: Float, height: Float)) {}
}

#endif
