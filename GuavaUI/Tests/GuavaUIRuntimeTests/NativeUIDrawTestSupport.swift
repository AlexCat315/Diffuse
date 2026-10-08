#if os(macOS)
import Foundation
import NativeRHI
import RHIWGPU
import Testing
@testable import GuavaUIRuntime

struct NativeUITestFormat {
    let native: TextureFormat
    let reference: GPUTextureFormat
    var bytesPerPixel: Int { native == .rgba16Float ? 8 : 4 }
    static let cases: [Self] = [
        Self(native: .rgba8Unorm, reference: .rgba8Unorm), Self(native: .bgra8Unorm, reference: .bgra8Unorm),
        Self(native: .rgba8UnormSRGB, reference: .rgba8UnormSrgb), Self(native: .bgra8UnormSRGB, reference: .bgra8UnormSrgb),
        Self(native: .rgba16Float, reference: .rgba16Float)
    ]
}

final class NativeUIDrawTestContext {
    let device: Device
    let backend: WGPUBackend
    let native: NativeDrawListRenderer
    let reference: DrawListRenderer

    init(validation: Bool = true) throws {
        device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: validation, framesInFlight: 3))
        backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: validation, preferredBackends: [.metal]))
        try backend.initialize()
        native = try NativeDrawListRenderer(device: device)
        reference = DrawListRenderer(backend: backend)
        try native.configure(format: .bgra8Unorm); try reference.configure(format: .bgra8Unorm)
    }

    func stage(id: TextureID, pixels: Data, size: SIMD2<Int>, region: TextureUploadRegion, format: TextureFormat) throws {
        try native.registerTexture(id: id, pixels: pixels, size: size, region: region, format: format)
        try pixels.withUnsafeBytes { raw in
            let pointer = try #require(raw.baseAddress?.assumingMemoryBound(to: UInt8.self))
            if format == .r8Unorm {
                try reference.registerAlphaTexture(id: id, pixels: pointer, width: UInt32(region.width), height: UInt32(region.height),
                    originX: UInt32(region.origin.x), originY: UInt32(region.origin.y), textureWidth: UInt32(size.x), textureHeight: UInt32(size.y))
            } else {
                try reference.registerColorTexture(id: id, pixels: pointer, width: UInt32(region.width), height: UInt32(region.height),
                    originX: UInt32(region.origin.x), originY: UInt32(region.origin.y), textureWidth: UInt32(size.x), textureHeight: UInt32(size.y))
            }
        }
    }

    func nativeOutput(format: TextureFormat, size: SIMD2<Int>) throws -> TextureResource {
        try TextureResource(device: device, descriptor: TextureDescriptor(width: size.x, height: size.y, format: format,
            usage: [.colorTarget, .transferSource, .transferDestination, .sampled]))
    }

    func nativeImage(list: DrawList, format: NativeUITestFormat, samples: Int, viewport: NativeUIViewport,
        renderer: NativeDrawListRenderer? = nil) throws -> (Data, NativeUIDrawStatistics) {
        let renderer = renderer ?? native
        try renderer.configure(format: format.native, sampleCount: samples)
        let output = try nativeOutput(format: format.native, size: viewport.pixels)
        let multisample = samples > 1 ? try TextureResource(device: device, descriptor: TextureDescriptor(width: viewport.pixels.x,
            height: viewport.pixels.y, format: format.native, usage: .colorTarget, sampleCount: samples)) : nil
        var target = RenderColorTarget(texture: (multisample ?? output).texture, loadAction: .clear(SIMD4(0.07, 0.09, 0.12, 0.5)))
        if samples > 1 { target.resolveTexture = output.texture; target.store = false }
        try device.beginFrame()
        do {
            let commands = CommandBuffer()
            let frame = try renderer.record(list: list, into: commands, target: target, viewport: viewport)
            try device.submit(commands); try renderer.didSubmit(frame)
            device.endFrame()
            try device.waitUntilIdle()
            return (try read(output, bytesPerPixel: format.bytesPerPixel), frame.statistics)
        } catch { device.endFrame(); throw error }
    }

    func read(_ resource: TextureResource, bytesPerPixel: Int = 4) throws -> Data {
        let descriptor = resource.descriptor
        var data = Data(count: descriptor.width * descriptor.height * bytesPerPixel)
        try data.withUnsafeMutableBytes {
            try device.readTextureData(resource.texture, width: descriptor.width, height: descriptor.height,
                bytesPerRow: descriptor.width * bytesPerPixel, into: $0)
        }
        return data
    }

    func referenceImage(list: DrawList, format: NativeUITestFormat, samples: Int, viewport: NativeUIViewport,
        renderer: DrawListRenderer? = nil) throws -> Data {
        let renderer = renderer ?? reference
        try renderer.configure(format: format.reference, sampleCount: UInt32(samples))
        let w = UInt32(viewport.pixels.x), h = UInt32(viewport.pixels.y)
        let output = try backend.createTexture(width: w, height: h, format: format.reference, usage: [.renderAttachment, .copySrc])
        let multisample = samples > 1 ? try backend.createTexture(width: w, height: h, format: format.reference,
            usage: .renderAttachment, sampleCount: UInt32(samples)) : nil
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(colorView: (multisample ?? output).createView(),
            resolveTargetView: multisample != nil ? output.createView() : nil,
            storeOp: multisample != nil ? .discard : .store, clearColor: GPUColor(r: 0.07, g: 0.09, b: 0.12, a: 0.5))
        try renderer.render(list: list, pass: pass, viewportPx: (w, h), coordinateSpace: (viewport.logical.x, viewport.logical.y))
        pass.end()
        let row = UInt32((viewport.pixels.x * format.bytesPerPixel + 255) / 256 * 256)
        let buffer = try backend.createBuffer(size: UInt64(row * h), usage: [.copyDst, .mapRead])
        encoder.copyTextureToBuffer(source: output, destination: buffer, bytesPerRow: row, rowsPerImage: h, width: w, height: h)
        backend.submit(try encoder.finish())
        try backend.bufferMapSync(buffer)
        defer { buffer.unmap() }
        let pointer = try #require(buffer.getMappedRange())
        var data = Data()
        for y in 0..<viewport.pixels.y {
            data.append(pointer.advanced(by: y * Int(row)).assumingMemoryBound(to: UInt8.self),
                        count: viewport.pixels.x * format.bytesPerPixel)
        }
        return data
    }
}

func expectNativeUIParity(_ native: Data, _ reference: Data, format: NativeUITestFormat, label: String) throws {
    #expect(native.count == reference.count)
    var maximum: Float = 0, sum: Float = 0, outliers = 0
    if format.bytesPerPixel == 8 {
        let a = native.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let b = reference.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        for (a, b) in zip(a, b) {
            let aa = Float(Float16(bitPattern: a)), bb = Float(Float16(bitPattern: b))
            #expect(aa.isFinite && bb.isFinite)
            let delta = abs(aa - bb); maximum = max(maximum, delta); sum += delta
            if delta > 0.002 { outliers += 1 }
        }
        #expect(maximum <= 0.002, Comment(rawValue: label + " HDR max=\(maximum)"))
    } else {
        for (a, b) in zip(native, reference) {
            let delta = abs(Float(a) - Float(b)); maximum = max(maximum, delta); sum += delta
            if delta > 3 { outliers += 1 }
        }
        #expect(maximum <= 3, Comment(rawValue: label + " max=\(maximum)"))
    }
    #expect(outliers == 0, Comment(rawValue: label + " outliers=\(outliers)"))
    print("native-ui-parity \(label) max=\(maximum) mean=\(sum / Float(native.count / (format.bytesPerPixel == 8 ? 2 : 1)))")
}

func nativeUIScene(_ context: NativeUIDrawTestContext) throws -> DrawList {
    let list = DrawList()
    list.addRoundedRect(UIRect(x: 2.3, y: 3.1, width: 55, height: 29), radius: 6.2, color: Color(r: 0.77, g: 0.2, b: 0.13, a: 0.7))
    list.addRect(UIRect(x: 5, y: 9, width: 32, height: 13), color: Color(r: 0.1, g: 0.5, b: 0.9, a: 0.35))
    list.addRoundedRectStroke(UIRect(x: 3, y: 38, width: 85, height: 18), radius: 4, width: 1.3, color: .white)
    list.addLine(fromX: 3.4, fromY: 36.7, toX: 152.2, toY: 58.8, thickness: 1.9, color: Color(r: 0.2, g: 0.7, b: 0.9, a: 0.65))
    var pixels = Data()
    for y in 0..<6 { for x in 0..<8 { pixels.append(contentsOf: [UInt8(13 + x * 28), UInt8(31 + y * 39), UInt8(255 - x * 20), UInt8(35 + (x + y) * 16)]) } }
    try context.stage(id: 2, pixels: pixels, size: SIMD2(8, 6), region: .init(width: 8, height: 6), format: .rgba8Unorm)
    var patch = TextureUploadRegion(width: 3, height: 2); patch.origin = SIMD2(2, 2)
    try context.stage(id: 2, pixels: Data(repeating: 111, count: 24), size: SIMD2(8, 6), region: patch, format: .rgba8Unorm)
    list.addImageQuad(rect: UIRect(x: 62.7, y: 4.9, width: 32.6, height: 25.4), textureID: 2,
        tint: Color(r: 0.9, g: 0.7, b: 0.4, a: 0.8), uvMin: (0.13, 0.17), uvMax: (0.9, 0.82))
    list.addImageMaskQuad(rect: UIRect(x: 100, y: 8, width: 28.7, height: 24.3), textureID: 2, tint: Color(r: 0.4, g: 0.85, b: 0.7, a: 0.75))
    list.addImageQuad(rect: UIRect(x: 141, y: 5, width: 8, height: 20), textureID: 999, tint: Color(red: 128, green: 49, blue: 200, alpha: 128))
    var alphaRegion = TextureUploadRegion(width: 3, height: 2); alphaRegion.origin = SIMD2(2, 1)
    try context.stage(id: 3, pixels: Data([0, 64, 128, 191, 224, 255]), size: SIMD2(8, 6), region: alphaRegion, format: .r8Unorm)
    let glyph = GlyphAtlasInfo(glyphIndex: 1, width: 28, height: 20, bearingX: 0, bearingY: 0, advance: 28,
        uvMinX: 0, uvMinY: 0, uvMaxX: 1, uvMaxY: 1)
    list.addAtlasGlyph(glyph, x: 96, y: 40, color: Color(r: 0.8, g: 0.75, b: 0.3, a: 0.9), textureID: 3)
    list.pushClip(UIRect(x: -2.1, y: 89.1, width: 62.2, height: 21.5))
    list.pushClip(UIRect(x: 12.3, y: 85, width: 98, height: 13.5))
    list.addRect(UIRect(x: 0, y: 80, width: 100, height: 35), color: Color(r: 0.7, g: 0.1, b: 0.6, a: 0.6))
    list.popClip(); list.popClip()
    list.pushClip(UIRect(x: 170, y: 0, width: 0, height: 10))
    list.addRect(UIRect(x: 0, y: 0, width: 160, height: 120), color: .white); list.popClip()
    let provider = FontProvider(size: 18, rasterScale: 2)
    _ = try #require(provider.loadPrimaryFont(name: SystemFontDefaults.primaryFontName))
    let atlas = FontAtlas(width: 512, height: 512)
    let glyphs = provider.resolveRuns(text: "Hello 中🙂").flatMap(provider.shapeRun)
    provider.registerAllFonts(in: atlas)
    var x: Float = 4
    for glyph in glyphs {
        let info = try #require(atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID))
        list.addAtlasGlyph(info, x: x + info.bearingX, y: 81 - info.bearingY,
            color: Color(r: 0.85, g: 0.93, b: 1, a: 0.83), textureID: 1)
        x += glyph.xAdvance
    }
    let alpha = atlas.dirtyUploadPayload(), color = atlas.colorDirtyUploadPayload()
    try context.native.uploadFontAtlas(atlas, textureID: 1)
    #expect(!atlas.isDirty)
    if let alpha {
        try alpha.pixels.withUnsafeBufferPointer { bytes in
            try context.reference.registerAlphaTexture(id: 1, pixels: bytes.baseAddress!, width: UInt32(alpha.region.width), height: UInt32(alpha.region.height),
                originX: UInt32(alpha.region.x), originY: UInt32(alpha.region.y), textureWidth: 512, textureHeight: 512)
        }
    }
    if let color {
        try color.pixels.withUnsafeBufferPointer { bytes in
            try context.reference.registerColorTexture(id: TextureID(1).colorGlyphAtlasID, pixels: bytes.baseAddress!, width: UInt32(color.region.width), height: UInt32(color.region.height),
                originX: UInt32(color.region.x), originY: UInt32(color.region.y), textureWidth: UInt32(color.textureWidth), textureHeight: UInt32(color.textureHeight))
        }
    }
    // Retain unused vertex/index prefixes, exercising firstIndex and packed stride.
    let prefix = DrawList(); prefix.addRect(UIRect(x: -50, y: -50, width: 1, height: 1), color: .white)
    let output = DrawList()
    output.load(vertices: prefix.vertices + list.vertices, indices: prefix.indices + list.indices.map { $0 + 4 },
        batches: list.batches.map { var batch = $0; batch.indexOffset += 6; return batch }, resources: list.resources)
    return output
}
#endif
