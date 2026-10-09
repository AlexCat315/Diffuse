#if os(macOS)
import Foundation
import XCTest
import EngineKernel
import NativeRHI
import NativeRendererValidation
import RenderBackend
import GuavaUICompose
import GuavaUIApp

private struct HUDTiming: Codable {
    let p50Microseconds: Double
    let p95Microseconds: Double
    let sampleCount: Int
    init(_ samples: [Double]) {
        let sorted = samples.sorted(); sampleCount = samples.count
        p50Microseconds = sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1]
        p95Microseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
}
private struct HUDBenchmarkResult: Codable {
    let backend: String
    let cpuTickAndScene: HUDTiming
    let cpuScene: HUDTiming
    let cpuHUDEncode: HUDTiming
    let completedBatch: HUDTiming
    let passFrames: [String: Int]
    let passDraws: [String: Int]
}
private struct HUDBenchmarkReport: Encodable {
    let device: String
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let measuredAt = ISO8601DateFormatter().string(from: Date())
    let buildConfiguration = "release"
    let timingMethod = "Main-thread HUD tick + scene CPU duration; GPU completion every three frames; no GPU timestamps or presentation"
    let width: UInt32
    let height: UInt32
    let post: Bool
    let logicalWidth = 1280
    let logicalHeight = 720
    let frames = 180
    let warmup = 30
    let repeats = 3
    let results: [HUDBenchmarkResult]
    let difference: GridImageDifference
}

final class NativeInGameUIBenchmarkTests: XCTestCase {
    @MainActor
    func testReleaseSceneAndHUDWorkload() async throws {
        guard ProcessInfo.processInfo.environment["GUAVA_NATIVE_HUD_BENCHMARK"] == "1" else {
            throw XCTSkip("opt-in release scene/HUD benchmark")
        }
        #if DEBUG
        throw RHIError.invalidArgument("run the HUD benchmark with swift test -c release")
        #else
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: false, framesInFlight: 3))
        let scene = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: false)
        let nativeHUD = try InGameUIHost(device: device), wgpuHUD = InGameUIHost(backend: reference.backend)
        nativeHUD.setRootView(Text("Guava NativeRHI HUD 中🙂")); wgpuHUD.setRootView(Text("Guava NativeRHI HUD 中🙂"))
        let old = InGameUIRegistry.shared.provider
        defer { InGameUIRegistry.shared.provider = old }
        for post in [false, true] { for size in [RenderDrawableSize(width: 1280, height: 720), .init(width: 1920, height: 1080)] {
            let scale = Float(size.width) / 1280
            func packet(_ frame: Int) -> RenderPacket {
                var p = post ? PostProbeScene.packet(size: size) : MeshProbeScene.packet(size: size)
                p.frameIndex = frame; p.scene.camera.eye.x += Float(frame % 11) * 0.002
                p.renderSettings.enableSSR = false; p.renderSettings.enableTAA = false
                for index in 0..<40 {
                    let x = Float(index % 8) * 155 + 12, y = Float(index / 8) * 130 + 40
                    p.inGameCanvas.rect(x: x, y: y, w: 144, h: 96, color: InGameUIColor(r: 0.06, g: 0.09, b: 0.15, a: 0.8), cornerRadius: 6)
                    p.inGameCanvas.label("Unit \(index) 中🙂", x: x + 8, y: y + 8, fontSize: 16)
                    p.inGameCanvas.progressBar(x: x + 8, y: y + 64, w: 124, h: 12, value: Float((frame + index) % 60) / 60)
                }
                return p
            }
            InGameUIRegistry.shared.provider = nativeHUD
            let native = try measure("native-metal", render: { frame in
                let p = packet(frame)
                nativeHUD.tick(width: 1280, height: 720, contentScale: scale, canvas: p.inGameCanvas)
                try scene.renderChecked(packet: p)
                XCTAssertFalse(scene.lastFrameUsedOpaqueCache)
                return scene.lastFrameStats
            }, finish: { try device.waitUntilIdle() })
            let actual = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size)
            InGameUIRegistry.shared.provider = wgpuHUD
            let wgpu = try measure("wgpu-metal", render: { frame in
                let p = packet(frame)
                wgpuHUD.tick(width: 1280, height: 720, contentScale: scale, canvas: p.inGameCanvas)
                let stats = try reference.render(packet: p)
                XCTAssertFalse(reference.renderer.lastFrameUsedOpaqueCache)
                return stats
            }, finish: { try reference.finish() })
            XCTAssertEqual(native.passFrames, wgpu.passFrames)
            XCTAssertEqual(native.passDraws, wgpu.passDraws)
            XCTAssertGreaterThan(native.passDraws[RenderPassKind.inGameUI.rawValue] ?? 0, 540)
            let delta = try GridImage.difference(actual, reference.readback())
            XCTAssertLessThan(delta.meanAbsoluteChannelError, 0.5)
            XCTAssertLessThan(Double(delta.pixelsOverThree) / Double(delta.pixelCount), 0.01)
            let report = HUDBenchmarkReport(device: device.deviceName, width: size.width, height: size.height, post: post,
                results: [native, wgpu], difference: delta)
            let root = ProcessInfo.processInfo.environment["GUAVA_NATIVE_HUD_BENCHMARK_OUTPUT"] ?? "/tmp/guava-native-hud-benchmark"
            let directory = URL(fileURLWithPath: root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("native-hud-\(post ? "post" : "mesh")-m1-\(size.height).json"))
            print("native-hud-benchmark post=\(post) size=\(size) nativeCPU=\(native.cpuTickAndScene.p50Microseconds) wgpuCPU=\(wgpu.cpuTickAndScene.p50Microseconds) nativeCompleted=\(native.completedBatch.p50Microseconds) wgpuCompleted=\(wgpu.completedBatch.p50Microseconds)")
        } }
        #endif
    }

    private func measure(_ backend: String, render: (Int) throws -> RenderFrameStats, finish: () throws -> Void) throws -> HUDBenchmarkResult {
        for frame in 0..<30 { _ = try render(frame); if (frame + 1) % 3 == 0 { try finish() } }
        try finish()
        var cpu: [Double] = [], scene: [Double] = [], hud: [Double] = [], completed: [Double] = []
        var passFrames: [String: Int] = [:], passDraws: [String: Int] = [:]
        for repetition in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            for frame in 0..<180 {
                let before = DispatchTime.now().uptimeNanoseconds
                let stats = try render(30 + repetition * 180 + frame)
                cpu.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1000)
                scene.append(Double(stats.cpuFrameTotalNS) / 1000)
                hud.append(Double(stats.passEncodeNS[.inGameUI] ?? 0) / 1000)
                for (kind, draws) in stats.passDrawCallCounts {
                    passFrames[kind.rawValue, default: 0] += 1; passDraws[kind.rawValue, default: 0] += draws
                }
                if (frame + 1) % 3 == 0 { try finish() }
            }
            completed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 180 / 1000)
        }
        return HUDBenchmarkResult(backend: backend, cpuTickAndScene: HUDTiming(cpu), cpuScene: HUDTiming(scene),
            cpuHUDEncode: HUDTiming(hud), completedBatch: HUDTiming(completed), passFrames: passFrames, passDraws: passDraws)
    }
}
#endif
