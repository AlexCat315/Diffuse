import GuavaUIDevToolsProtocol
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Logging)
import GuavaLogging
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import NativeRHI
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


    public final class Sink: @unchecked Sendable {
        public init() {}
        /// Set by `DevTools` once the server is ready to forward frames.
        public var deliver: ((MirrorFramePayload) -> Void)?
    }

    private let sink: Sink
    private let capturePixels: Capture
    private let resetCapture: () -> Void

    private var enabled = false
    private var quality: Double = 0.7
    private var scale: Double = 1
    private var minFrameInterval: TimeInterval = 1.0 / 15.0
    private var lastCaptureAt: TimeInterval = 0

    private var seq: UInt64 = 0
    #if canImport(Logging)
    private let log = LogSystem.logger("guava.devtools.frameTap")
    #endif
    /// Counts consecutive capture failures to throttle warning spam.
    private var consecutiveErrors: Int = 0
    private var capturesSinceStart: Int = 0


    public init(sink: Sink, capture: @escaping Capture, reset: @escaping () -> Void = {}) {
        self.sink = sink
        capturePixels = capture
        resetCapture = reset
    }

    public var isActive: Bool { enabled }

    public func start(fps: Double, quality: Double, scale: Double = 1) {
        self.scale = scale.isFinite ? max(1, min(3, scale)) : 1
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
        resetCapture()
    }

    /// Render the same draw list through the selected capture source and
    /// emit a `mirror.frame` to clients. Called by `Application.handleFrame`
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
        // Visual acceptance may ask for more, up to the native pixel density.
        let native = Double(widthPx) / Double(max(1, logical.width))
        let targetSize = Self.targetSize(logical: logical, scale: min(scale, max(1, native)))
        let captureWidthPx = targetSize.width
        let captureHeightPx = targetSize.height

        let now = Date().timeIntervalSince1970
        if now - lastCaptureAt < minFrameInterval { return }
        lastCaptureAt = now

        do {
            let pixels = try capturePixels(drawList, captureWidthPx, captureHeightPx, logical)
            let height = Int(captureHeightPx)
            guard pixels.bytesPerRow >= Int(captureWidthPx) * 4,
                  pixels.bytesPerRow <= Int.max / height,
                  pixels.data.count >= pixels.bytesPerRow * height else {
                throw RHIError.invalidArgument("mirror pixel buffer is incomplete")
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
            // flooding the host log when capture keeps failing.
            if consecutiveErrors <= 3 || consecutiveErrors % 60 == 0 {
                #if canImport(Logging)
                log.warning("mirror capture failed (#\(consecutiveErrors)): \(error)")
                #endif
            }
        }
    }

    private static func targetSize(logical: (width: Float, height: Float), scale requested: Double) -> (width: UInt32, height: UInt32) {
        let logicalWidth = max(1, Double(logical.width))
        let logicalHeight = max(1, Double(logical.height))
        let budget = requested > 1 ? (3_840.0, 2_160.0) : (1_920.0, 1_080.0)
        let scale = min(requested, min(budget.0 / logicalWidth, budget.1 / logicalHeight))
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
        // CGDataProvider needs ownership of a copy for the duration of image encoding.
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

    public init(sink: Sink, capture: @escaping Capture, reset: @escaping () -> Void = {}) {}
    public func start(fps: Double, quality: Double, scale: Double = 1) {}
    public func stop() {}
    public func capture(drawList: DrawList,
                        widthPx: UInt32,
                        heightPx: UInt32,
                        logical: (width: Float, height: Float)) {}
}

#endif
