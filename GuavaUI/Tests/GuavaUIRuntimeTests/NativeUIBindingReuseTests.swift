#if os(macOS)
import Foundation
import NativeRHI
import Testing
@testable import GuavaUIRuntime

@Suite("Native UI image binding reuse", .serialized)
struct NativeUIBindingReuseTests {
    @Test("image bindings survive viewport, color-space and frame-ring changes")
    func recordingConstantsAreIndependent() throws {
        let context = try NativeUIDrawTestContext()
        try context.stage(id: 77, pixels: Data([179, 113, 211, 193]), size: SIMD2(1, 1),
            region: .init(width: 1, height: 1), format: .rgba8Unorm)
        let list = DrawList()
        list.addImageQuad(rect: UIRect(x: 2, y: 3, width: 8, height: 6), textureID: 77,
            tint: Color(red: 113, green: 191, blue: 77, alpha: 211))
        let viewports = [NativeUIViewport(pixels: SIMD2(32, 24), logical: SIMD2(32, 24)),
                         NativeUIViewport(pixels: SIMD2(32, 24), logical: SIMD2(16, 12))]
        let formats = [NativeUITestFormat.cases[1], NativeUITestFormat.cases[3]]
        let outputs = try formats.map { try context.nativeOutput(format: $0.native, size: viewports[0].pixels) }
        let clear = SIMD4<Float>(0.07, 0.09, 0.12, 0.5)
        // Reconfigure the same renderer between two passes in one submission.
        // More than three frames also exercises upload-ring reuse without idle waits.
        for frameIndex in 0..<8 {
            let previous = context.device.bindingSetCacheStats
            try context.device.beginFrame()
            do {
                let commands = CommandBuffer()
                var recordings: [NativeUIDrawFrame] = []
                for index in formats.indices {
                    try context.native.configure(format: formats[index].native)
                    let frame = try context.native.record(list: list, into: commands,
                        target: RenderColorTarget(texture: outputs[index].texture, loadAction: .clear(clear)),
                        viewport: viewports[index])
                    recordings.append(frame)
                    if frameIndex > 0 { #expect(frame.statistics.textureUploads == 0) }
                }
                try context.device.submit(commands)
                recordings.forEach { $0.didSubmit() }
                context.device.endFrame()
            } catch { context.device.endFrame(); throw error }
            let delta = context.device.bindingSetCacheStats.delta(since: previous)
            #expect(delta.hits == (frameIndex == 0 ? 1 : 2))
            #expect(delta.misses == (frameIndex == 0 ? 1 : 0))
            #expect(delta.evictions == 0)
            // Change upload sizes every frame. Fixed geometry can accidentally
            // reuse a transient uniform's offset after the frame ring wraps.
            list.addImageQuad(rect: UIRect(x: -10, y: -10, width: 1, height: 1), textureID: 77)
        }
        try context.device.waitUntilIdle()
        for index in formats.indices {
            let actual = try context.read(outputs[index])
            let expected = try context.referenceImage(list: list, format: formats[index], samples: 1,
                viewport: viewports[index])
            try expectNativeUIParity(actual, expected, format: formats[index], label: "binding-reuse/\(index)")
        }
    }
}
#endif
