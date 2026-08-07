import EditorCore
import GuavaUICompose
import SceneRuntime
import SIMDCompat
import Testing

@Suite("EditorViewportProjection")
struct EditorViewportProjectionTests {

    private func makeProjection() -> EditorViewportProjection {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, 5),
                                  target: .zero,
                                  up: SIMD3<Float>(0, 1, 0),
                                  fovYRadians: .pi / 4,
                                  near: 0.1, far: 100)
        let frame = ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        return EditorViewportProjection(camera: camera, frame: frame)!
    }

    @Test("degenerate frame or camera fails to construct")
    func degenerateInitsFail() {
        let camera = RenderCamera(eye: .zero, target: .zero) // zero forward vector
        #expect(EditorViewportProjection(camera: camera,
                                         frame: ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)) == nil)

        let ok = RenderCamera(eye: SIMD3<Float>(0, 0, 5), target: .zero)
        #expect(EditorViewportProjection(camera: ok,
                                         frame: ViewportScreenFrame(x: 0, y: 0, width: 0, height: 600)) == nil)
    }

    @Test("camera target projects to the screen center")
    func targetProjectsToCenter() {
        let p = makeProjection()
        let screen = p.project(.zero)
        #expect(screen != nil)
        #expect(abs(screen!.x - 400) < 0.5) // frame center x
        #expect(abs(screen!.y - 300) < 0.5) // frame center y
    }

    @Test("a point behind the camera does not project")
    func pointBehindCameraReturnsNil() {
        let p = makeProjection()
        // Camera at z=5 looking toward origin (-z); a point further along +z is behind it.
        #expect(p.project(SIMD3<Float>(0, 0, 10)) == nil)
    }

    @Test("center cursor ray points along the camera forward axis")
    func centerRayMatchesForward() {
        let p = makeProjection()
        let ray = p.cursorRay(x: 400, y: 300)
        #expect(simd_distance(ray.origin, SIMD3<Float>(0, 0, 5)) < 1e-5)
        // Forward is toward origin: (0,0,-1).
        #expect(simd_distance(ray.direction, SIMD3<Float>(0, 0, -1)) < 1e-4)
    }

    @Test("project then cursorRay round-trips through the same screen point")
    func projectCursorRayRoundTrip() {
        let p = makeProjection()
        let world = SIMD3<Float>(1.5, -0.8, 0)
        let screen = p.project(world)!
        let ray = p.cursorRay(x: screen.x, y: screen.y)
        // The ray from the camera through that pixel must pass through the world point:
        // (world - origin) is parallel to the ray direction.
        let toPoint = simd_normalize(world - ray.origin)
        #expect(simd_distance(toPoint, simd_normalize(ray.direction)) < 1e-3)
    }

    @Test("cursor ray tilts right for pixels right of center")
    func rayTiltsWithCursor() {
        let p = makeProjection()
        let left = p.cursorRay(x: 200, y: 300)
        let right = p.cursorRay(x: 600, y: 300)
        // Rightward pixel ⇒ larger world-space X component than leftward pixel.
        #expect(right.direction.x > left.direction.x)
    }

    @Test("framing centers and safely fits every world-bounds corner")
    func framingFitsWorldBounds() {
        let boundsMin = SIMD3<Float>(-1.5, -3, -0.75)
        let boundsMax = SIMD3<Float>(2.5, 5, 1.25)
        let aspect: Float = 16.0 / 9.0
        let source = RenderCamera(eye: SIMD3<Float>(8, 5, 11),
                                  target: SIMD3<Float>(1, 1, 0),
                                  fovYRadians: .pi / 4,
                                  aspectRatio: aspect,
                                  near: 0.1,
                                  far: 500)
        let pose = EditorViewportFraming.pose(camera: source,
                                              boundsMin: boundsMin,
                                              boundsMax: boundsMax,
                                              viewportAspectRatio: aspect)
        let expectedCenter = (boundsMin + boundsMax) * 0.5
        #expect(simd_distance(pose.target, expectedCenter) < 1e-5)

        var framed = source
        framed.eye = pose.eye
        framed.target = pose.target
        let frame = ViewportScreenFrame(x: 0, y: 0, width: 1600, height: 900)
        let projection = EditorViewportProjection(camera: framed, frame: frame)!
        for x in [boundsMin.x, boundsMax.x] {
            for y in [boundsMin.y, boundsMax.y] {
                for z in [boundsMin.z, boundsMax.z] {
                    let screen = projection.project(SIMD3<Float>(x, y, z))
                    #expect(screen != nil)
                    #expect(screen!.x >= 80 && screen!.x <= 1520)
                    #expect(screen!.y >= 45 && screen!.y <= 855)
                }
            }
        }
    }

    @Test("framing honors a narrow viewport and repairs a degenerate camera")
    func framingHandlesNarrowViewportAndDegenerateCamera() {
        let boundsMin = SIMD3<Float>(-2, -1, -1)
        let boundsMax = SIMD3<Float>(2, 1, 1)
        let camera = RenderCamera(eye: .zero,
                                  target: .zero,
                                  fovYRadians: .pi / 3,
                                  near: 0.1,
                                  far: 100)
        let pose = EditorViewportFraming.pose(camera: camera,
                                              boundsMin: boundsMin,
                                              boundsMax: boundsMax,
                                              viewportAspectRatio: 0.5)
        #expect(pose.eye.x.isFinite && pose.eye.y.isFinite && pose.eye.z.isFinite)
        #expect(simd_distance(pose.eye, pose.target) > 4)

        var framed = camera
        framed.eye = pose.eye
        framed.target = pose.target
        let projection = EditorViewportProjection(
            camera: framed,
            frame: ViewportScreenFrame(x: 0, y: 0, width: 400, height: 800)
        )!
        for x in [boundsMin.x, boundsMax.x] {
            for y in [boundsMin.y, boundsMax.y] {
                for z in [boundsMin.z, boundsMax.z] {
                    let screen = projection.project(SIMD3<Float>(x, y, z))
                    #expect(screen != nil)
                    #expect(screen!.x >= 20 && screen!.x <= 380)
                    #expect(screen!.y >= 40 && screen!.y <= 760)
                }
            }
        }
    }
}
