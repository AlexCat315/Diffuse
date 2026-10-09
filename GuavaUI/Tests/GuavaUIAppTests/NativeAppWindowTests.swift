#if os(macOS)
import AppKit
import Foundation
import ImageIO
import XCTest
import GuavaUICompose
import GuavaUIDevTools
import NativeRHI
import NativeRendererValidation
import RenderBackend
import RHIWGPU
@testable import GuavaUIApp
@testable import GuavaUIRuntime

private final class WindowSceneWorker: @unchecked Sendable {
    private let renderer: NativeGridRenderer
    private let queue = DispatchQueue(label: "native-window-scene-test")
    private let lock = NSLock()
    private var failures: [String] = []
    init(device: Device) throws { renderer = try NativeGridRenderer(device: device) }
    func enqueue(frame: Int) {
        queue.async { [self] in
            do { try renderer.renderChecked(packet: GridProbeScene.packet(size: .init(width: 64, height: 48), frame: frame)) }
            catch { lock.withLock { failures.append(String(describing: error)) } }
        }
    }
    func finish() -> [String] { queue.sync {}; return lock.withLock { failures } }
}

final class NativeAppWindowTests: XCTestCase {
    @MainActor
    func testWGPUDefaultStillPresentsMainAndAuxiliaryWindows() async throws {
        var display: AppDisplayHandle?, auxiliary: WindowID?, frames = 0
        let oldText = TextEnvironmentHolder.current, oldScale = ContentScaleHolder.current
        defer { TextEnvironmentHolder.current = oldText; ContentScaleHolder.current = oldScale }
        try AppRuntime.run(config: AppConfig(title: "WGPU default host regression", targetFrameRate: 60), onTick: { _ in
            frames += 1
            if frames == 3 { auxiliary = display?.openWindow(title: "WGPU auxiliary", width: 240, height: 160) { Text("Aux 中🙂") } }
            if frames == 6 { display?.setVSyncEnabled(false) }
            if frames == 10, let auxiliary { display?.closeWindow(auxiliary) }
            if frames == 12 { display?.quit() }
        }, onDisplayReady: { display = $0 }) { Text("WGPU main 中🙂").padding(12) }
        XCTAssertNotNil(auxiliary); XCTAssertGreaterThanOrEqual(frames, 12)
        if let auxiliary { XCTAssertFalse(display?.isWindowOpen(auxiliary) ?? true) }
    }

    @MainActor
    func testWindowTargetsResizeSuspendAndCloseIndependently() async throws {
        _ = NSApplication.shared
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true, framesInFlight: 2))
        let context = try AppRenderingContext(device: .native(device), config: AppConfig())
        try context.initialize()
        func window(_ size: Int) throws -> (NSWindow, CAMetalLayer) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = try XCTUnwrap(window.contentView), layer = CAMetalLayer()
            view.wantsLayer = true; view.layer = layer; layer.frame = view.bounds
            return (window, layer)
        }
        let (a, layerA) = try window(64), (b, layerB) = try window(48)
        defer { a.close(); b.close() }
        let settings = AppWindowRenderSettings(config: AppConfig())
        let first = try context.makeWindow(settings: settings), second = try context.makeWindow(settings: settings)
        try first.configure(native: .metalLayer(Unmanaged.passUnretained(layerA).toOpaque()), size: SIMD2(64, 64), vsync: false)
        try second.configure(native: .metalLayer(Unmanaged.passUnretained(layerB).toOpaque()), size: SIMD2(48, 48), vsync: true)
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 32, height: 32), color: Color(r: 1, g: 0, b: 0))
        list.addRoundedRect(UIRect(x: 3, y: 3, width: 26, height: 26), radius: 5, color: Color(r: 0, g: 1, b: 0))
        for frame in 0..<24 {
            if frame == 8 { try first.resize(size: SIMD2(40, 24), vsync: false) }
            if frame == 12 {
                try first.resize(size: .zero, vsync: false)
                XCTAssertFalse(try first.draw(list: list, logical: SIMD2(32, 32)))
                try first.resize(size: SIMD2(40, 24), vsync: true)
            }
            XCTAssertTrue(try first.draw(list: list, logical: SIMD2(32, 32)))
            XCTAssertTrue(try second.draw(list: list, logical: SIMD2(32, 32)))
        }
        XCTAssertEqual(layerA.drawableSize, CGSize(width: 40, height: 24))
        XCTAssertEqual(layerB.drawableSize, CGSize(width: 48, height: 48))
        XCTAssertTrue(layerA.framebufferOnly); XCTAssertTrue(layerB.framebufferOnly)
        try first.close(); try first.close()
        XCTAssertFalse(try first.draw(list: list, logical: SIMD2(32, 32)))
        XCTAssertTrue(try second.draw(list: list, logical: SIMD2(32, 32)))
        try second.close()
        XCTAssertFalse(first.isConfigured); XCTAssertFalse(second.isConfigured)
        try device.waitUntilIdle()
    }

    @MainActor
    func testNativeMirrorMatchesWGPUAndResetsCaptureResources() async throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let native = try NativeDrawListRenderer(device: device)
        try native.configure(format: .bgra8UnormSRGB, sampleCount: 4)
        let capture = try NativeAppFrameCapture(device: device, renderer: native)
        let backend = WGPUBackend(config: .init(validationEnabled: true, preferredBackends: [.metal]))
        try backend.initialize()
        let reference = DrawListRenderer(backend: backend)
        try reference.configure(format: .bgra8UnormSrgb, sampleCount: 4)
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 64, height: 48), color: Color(r: 1, g: 0, b: 0))
        list.pushClip(UIRect(x: 8, y: 8, width: 40, height: 24))
        list.addRect(UIRect(x: 0, y: 0, width: 64, height: 48), color: Color(r: 0, g: 1, b: 0))
        list.popClip()
        let nativeSink = FrameTap.Sink(), referenceSink = FrameTap.Sink()
        var nativeJPEG: Data?, referenceJPEG: Data?, resetCount = 0
        nativeSink.deliver = { nativeJPEG = Data(base64Encoded: $0.jpegBase64) }
        referenceSink.deliver = { referenceJPEG = Data(base64Encoded: $0.jpegBase64) }
        let nativeTap = FrameTap(sink: nativeSink, capture: { list, width, height, logical in
            try capture.capture(list: list, size: SIMD2(Int(width), Int(height)), logical: SIMD2(logical.width, logical.height))
        }, reset: { capture.reset(); resetCount += 1 })
        let referenceTap = FrameTap(sink: referenceSink, backend: backend, renderer: reference)
        for size in [SIMD2(64, 48), SIMD2(96, 72)] {
            nativeTap.start(fps: 60, quality: 0.9); referenceTap.start(fps: 60, quality: 0.9)
            let logical = (width: Float(64), height: Float(48))
            nativeTap.capture(drawList: list, widthPx: UInt32(size.x), heightPx: UInt32(size.y), logical: logical)
            referenceTap.capture(drawList: list, widthPx: UInt32(size.x), heightPx: UInt32(size.y), logical: logical)
            let jpeg = try XCTUnwrap(nativeJPEG)
            XCTAssertEqual(jpeg, try XCTUnwrap(referenceJPEG))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 48)
            nativeTap.stop(); referenceTap.stop()
        }
        XCTAssertEqual(resetCount, 2)
        try device.waitUntilIdle()
    }

    @MainActor
    func testAppRuntimeNativeWindowsShareDeviceWithSceneWorker() async throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let worker = try WindowSceneWorker(device: device)
        var display: AppDisplayHandle?, auxiliary: WindowID?, frames = 0, opened = 0
        let oldText = TextEnvironmentHolder.current, oldScale = ContentScaleHolder.current
        defer { TextEnvironmentHolder.current = oldText; ContentScaleHolder.current = oldScale }
        try AppRuntime.run(config: AppConfig(title: "NativeRHI UI host regression", targetFrameRate: 60),
            backend: .native(device), onTick: { _ in
                frames += 1; worker.enqueue(frame: frames)
                if frames == 3 || frames == 14 {
                    auxiliary = display?.openWindow(title: "NativeRHI auxiliary", width: 240, height: 160) { Text("Aux 中🙂") }
                    if auxiliary != nil { opened += 1 }
                }
                if frames == 6 { display?.setVSyncEnabled(false) }
                if frames == 10, let auxiliary { display?.closeWindow(auxiliary) }
                if frames == 18 { display?.quit() }
            }, onDisplayReady: { display = $0 }) { Text("Native main 中🙂").padding(12) }
        XCTAssertEqual(opened, 2); XCTAssertGreaterThanOrEqual(frames, 18)
        if let auxiliary { XCTAssertFalse(display?.isWindowOpen(auxiliary) ?? true) }
        XCTAssertTrue(worker.finish().isEmpty)
        try device.waitUntilIdle()
    }
}
#endif
