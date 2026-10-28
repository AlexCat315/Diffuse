import NativeRHI
@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Geometry overlay clipping")
struct GeometryOverlayTests {
    @Test("homogeneous line clipping handles near/far/side planes and rejects points behind the camera")
    func clipping() throws {
        let near = try #require(NativeOverlayGeometry.clipLine(SIMD4(0,0,-1,1),SIMD4(0,0,0.5,1)))
        #expect(abs(near.0.z) < 1e-6 && near.1.z == 0.5)
        let across = try #require(NativeOverlayGeometry.clipLine(SIMD4(-3,0,0.5,1),SIMD4(3,0,0.5,1)))
        #expect(abs(across.0.x+1) < 1e-6 && abs(across.1.x-1) < 1e-6)
        #expect(NativeOverlayGeometry.clipLine(SIMD4(0,0,2,1),SIMD4(1,0,3,1)) == nil)
        #expect(NativeOverlayGeometry.clipLine(SIMD4(0,0,0,-1),SIMD4(1,0,0,-1)) == nil)
    }

    @Test("pixel widths remain stable at different output resolutions and invalid input is rejected")
    func expansion() throws {
        var overlay = RenderGeometryOverlay(viewportSize: SIMD2(800,600))
        overlay.lines = [.init(SIMD3(-0.5,0,0.5),SIMD3(0.5,0,0.5),color: SIMD4(1,0.5,0,1),width: 2)]
        let vertices = try NativeOverlayGeometry.make(overlay,matrix: matrix_identity_float4x4)
        #expect(vertices.count == 6)
        #expect(abs(vertices[2].position.y-vertices[1].position.y-4/600) < 1e-6)
        overlay.lines[0].width = .nan
        #expect(throws: (any Error).self) { try NativeOverlayGeometry.make(overlay,matrix: matrix_identity_float4x4) }
        overlay.lines[0].width = 2; overlay.lines[0].a.x = .infinity
        #expect(throws: (any Error).self) { try NativeOverlayGeometry.make(overlay,matrix: matrix_identity_float4x4) }
    }
}
