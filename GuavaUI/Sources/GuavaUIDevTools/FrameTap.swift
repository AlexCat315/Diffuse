import Foundation
import CoreGraphics
import ImageIO
import Logging
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import RHIWGPU
import GuavaUIRuntime

/// Captures a copy of each rendered frame into an offscreen texture, reads it
/// back into a CPU buffer, JPEG-encodes it via ImageIO and pushes the result
/// to attached DevTools clients.
///
/// The mirror runs on the host's main thread because it shares the wgpu device
/// and `DrawListRenderer` with the primary surface render path. To avoid
/// stalling the host every frame the tap is rate-limited (default 15fps) and
/// silently drops a frame if the previous one's GPU readback has not yet
/// completed.
@MainActor
public final class FrameTap {

    public final class Sink: @unchecked Sendable {
        public init() {}
        /// Set by `DevTools` once the server is ready to forward frames.
        public var deliver: ((MirrorFramePayload) -> Void)?
    }

    /// wgpu requires `bytesPerRow` to be a multiple of this value when
    /// copying texture → buffer.
    private static let copyBytesPerRowAlignment: Int = 256

    private let sink: Sink
    private let backend: WGPUBackend
    private let renderer: DrawListRenderer

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

    private let log = Logger(label: "guava.devtools.frameTap")
    /// Counts consecutive capture failures to throttle warning spam.
    private var consecutiveErrors: Int = 0
    private var capturesSinceStart: Int = 0

    public init(sink: Sink, backend: WGPUBackend, renderer: DrawListRenderer) {
        self.sink = sink
        self.backend = backend
        self.renderer = renderer
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
        print("[guava.devtools.frameTap] start fps=\(clampedFps) quality=\(self.quality)")
        log.info("mirror start fps=\(clampedFps) quality=\(self.quality)")
    }

    public func stop() {
        enabled = false
        log.info("mirror stop after \(capturesSinceStart) captures, errors=\(consecutiveErrors)")
        // Drop GPU resources so the next start() picks up the latest size.
        texture = nil
        textureView = nil
        readback = nil
        widthPx = 0
        heightPx = 0
        bytesPerRow = 0
    }

    /// Render the same draw list to an offscreen texture, copy it back and
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
        if capturesSinceStart == 0 && consecutiveErrors == 0 {
            // Only log first time to confirm the call site is wired.
            print("[guava.devtools.frameTap] capture() called, enabled, drawable=\(widthPx)x\(heightPx) logical=\(logical.width)x\(logical.height)")
        }
        guard sink.deliver != nil else {
            if capturesSinceStart == 0, consecutiveErrors == 0 {
                print("[guava.devtools.frameTap] enabled but sink.deliver is nil")
                log.warning("mirror enabled but sink.deliver is nil; broadcaster not wired")
                consecutiveErrors = 1
            }
            return
        }
        guard widthPx > 0, heightPx > 0 else {
            if capturesSinceStart == 0, consecutiveErrors == 0 {
                print("[guava.devtools.frameTap] zero-sized drawable \(widthPx)x\(heightPx)")
                log.warning("mirror capture skipped: zero-sized drawable \(widthPx)x\(heightPx)")
                consecutiveErrors = 1
            }
            return
        }

        let now = Date().timeIntervalSince1970
        if now - lastCaptureAt < minFrameInterval { return }
        lastCaptureAt = now

        do {
            try ensureResources(widthPx: widthPx, heightPx: heightPx)
            guard let texture, let textureView, let readback else { return }

            let encoder = try backend.createCommandEncoder()
            let pass = try encoder.beginRenderPass(
                colorView: textureView,
                loadOp: .clear,
                storeOp: .store,
                clearColor: .black
            )
            try renderer.render(
                list: drawList,
                pass: pass,
                viewportPx: (widthPx, heightPx),
                coordinateSpace: (logical.width, logical.height)
            )
            pass.end()
            encoder.copyTextureToBuffer(
                source: texture,
                destination: readback,
                bufferOffset: 0,
                bytesPerRow: UInt32(bytesPerRow),
                rowsPerImage: heightPx,
                width: widthPx,
                height: heightPx
            )
            let commandBuffer = try encoder.finish()
            backend.submit(commandBuffer)

            try backend.bufferMapSync(readback)
            defer { readback.unmap() }
            guard let mapped = readback.getMappedRange(offset: 0, size: UInt64(bytesPerRow * Int(heightPx))) else {
                return
            }

            guard let jpeg = encodeJPEG(
                bgra: mapped,
                width: Int(widthPx),
                height: Int(heightPx),
                bytesPerRow: bytesPerRow,
                quality: quality
            ) else {
                return
            }

            seq &+= 1
            capturesSinceStart &+= 1
            consecutiveErrors = 0
            if capturesSinceStart == 1 {
                print("[guava.devtools.frameTap] first frame seq=\(seq) px=\(widthPx)x\(heightPx) jpeg=\(jpeg.count)B")
                log.info("mirror first frame seq=\(seq) px=\(widthPx)x\(heightPx) jpeg=\(jpeg.count)B")
            }
            sink.deliver?(MirrorFramePayload(
                seq: seq,
                width: Int(widthPx),
                height: Int(heightPx),
                logicalWidth: Double(logical.width),
                logicalHeight: Double(logical.height),
                jpegBase64: jpeg.base64EncodedString()
            ))
        } catch {
            consecutiveErrors &+= 1
            // Log the first 3 failures and every 60th after that to avoid
            // flooding the host log when wgpu is in a permanently bad state.
            if consecutiveErrors <= 3 || consecutiveErrors % 60 == 0 {
                print("[guava.devtools.frameTap] capture failed (#\(consecutiveErrors)): \(error)")
                log.warning("mirror capture failed (#\(consecutiveErrors)): \(error)")
            }
        }
    }

    // MARK: - Resources

    private func ensureResources(widthPx: UInt32, heightPx: UInt32) throws {
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
