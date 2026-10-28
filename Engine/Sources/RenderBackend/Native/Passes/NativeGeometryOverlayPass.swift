import Foundation
import NativeRHI
import SceneRuntime

final class NativeGeometryOverlayPass {
    private let device: Device
    private let visible: GraphicsPipeline
    private let xray: GraphicsPipeline

    init(device: Device) throws {
        self.device = device
        let vertex = try device.makeShaderModule(NativeShaderLibrary.artifact(name: "editor_geometry",api: device.backendAPI,stage: .vertex).moduleDescriptor())
        defer { device.destroy(vertex) }
        let fragment = try device.makeShaderModule(NativeShaderLibrary.artifact(name: "editor_geometry",api: device.backendAPI,stage: .fragment).moduleDescriptor())
        defer { device.destroy(fragment) }
        let layout = try device.makePipelineLayout(.init(setLayouts: []))
        let vertices = VertexLayoutDescriptor(attributes: (0..<7).map { .init(location: UInt32($0),format: .float4,offset: $0*16) },
            bufferLayouts: [.init(stride: MemoryLayout<NativeOverlayVertex>.stride)])
        func pipeline(_ compare: CompareOp) throws -> GraphicsPipeline {
            try device.makeGraphicsPipeline(.init(layout: layout,vertex: vertex,fragment: fragment,
                colorAttachments: [.init(format: .bgra8Unorm,blend: .alphaBlend)],
                rasterization: .init(cullMode: .none),
                depthStencil: .init(depthCompare: compare,depthWriteEnabled: false),
                vertexLayout: vertices,label: "editor-geometry-\(compare)"))
        }
        visible = try pipeline(.lessOrEqual)
        do { xray = try pipeline(.always) }
        catch { device.destroy(visible); throw error }
    }
    deinit { device.destroy(visible); device.destroy(xray) }

    func encode(packet: RenderPacket,color: Texture,depth: Texture,into commands: CommandBuffer) throws -> Int {
        let matrix = RenderCameraMatrices.make(scene: packet.scene,drawableSize: packet.drawableSize).viewProjection
        var draws = 0
        for overlay in packet.scene.geometryOverlays where !overlay.isEmpty {
            let vertices = try NativeOverlayGeometry.make(overlay,matrix: matrix,pixelScale: Float(packet.drawableSize.height)/overlay.viewportSize.y)
            guard !vertices.isEmpty else { continue }
            let data = vertices.withUnsafeBytes { Data($0) }, upload = try device.uploadTransient(data)
            commands.renderPass(descriptor: .init(colorTargets: [.init(texture: color,loadAction: .load)],
                depthTarget: .init(texture: depth,loadAction: .load))) { pass in
                pass.setPipeline(overlay.xray ? xray : visible)
                pass.setViewport(.init(width: Double(packet.drawableSize.width),height: Double(packet.drawableSize.height)))
                pass.setScissor(.init(width: Int(packet.drawableSize.width),height: Int(packet.drawableSize.height)))
                pass.setVertexBuffer(upload.buffer,offset: upload.offset)
                pass.draw(vertexCount: vertices.count)
            }
            draws += 1
        }
        return draws
    }
}
