import EditorCore
import GuavaUICompose
import SceneRuntime
import SIMDCompat
import Testing

@Suite("EditorViewportProjection")
struct EditorViewportProjectionTests {
    @Test("orthographic picking rays are parallel, offset, and round-trip at every depth")
    func orthographicParallelRays() throws {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, 5), target: .zero,
                                  near: 0.1, far: 100,
                                  projection: .orthographic, orthographicHeight: 6)
        let p = try #require(EditorViewportProjection(camera: camera,
            frame: ViewportScreenFrame(x: 40, y: 20, width: 800, height: 600)))
        let left = p.cursorRay(x: 240, y: 320)
        let right = p.cursorRay(x: 640, y: 320)
        #expect(left.direction == SIMD3<Float>(0, 0, -1))
        #expect(left.direction == right.direction)
        #expect(abs(right.origin.x - left.origin.x - 4) < 1e-5)
        #expect(abs(left.origin.z - 4.9) < 1e-5)
        let nearPoint = try #require(p.project(SIMD3<Float>(1.5, -0.8, 0)))
        let farPoint = try #require(p.project(SIMD3<Float>(1.5, -0.8, -40)))
        #expect(abs(nearPoint.x - farPoint.x) < 1e-5)
        #expect(abs(nearPoint.y - farPoint.y) < 1e-5)
        let ray = p.cursorRay(x: nearPoint.x, y: nearPoint.y)
        #expect(abs(ray.origin.x - 1.5) < 1e-5 && abs(ray.origin.y + 0.8) < 1e-5)
        #expect(p.project(SIMD3<Float>(0, 0, 4.95)) == nil)
        #expect(p.project(SIMD3<Float>(0, 0, -100)) == nil)
    }

    @Test("orthographic framing fits bounds even in a narrow viewport")
    func orthographicFramingFits() throws {
        var camera = RenderCamera(eye: SIMD3<Float>(6, 5, 8), target: .zero,
                                  projection: .orthographic, orthographicHeight: 1)
        let lower = SIMD3<Float>(-2, -1, -3)
        let upper = SIMD3<Float>(4, 5, 1)
        let pose = EditorViewportFraming.pose(camera: camera, boundsMin: lower, boundsMax: upper,
                                              viewportAspectRatio: 0.5)
        camera.eye = pose.eye
        camera.target = pose.target
        camera.up = pose.up
        camera.orthographicHeight = try #require(pose.orthographicHeight)
        let p = try #require(EditorViewportProjection(camera: camera,
            frame: ViewportScreenFrame(x: 0, y: 0, width: 400, height: 800)))
        for x in [lower.x, upper.x] {
            for y in [lower.y, upper.y] {
                for z in [lower.z, upper.z] {
                    let screen = try #require(p.project(SIMD3<Float>(x, y, z)))
                    #expect(screen.x >= 20 && screen.x <= 380)
                    #expect(screen.y >= 40 && screen.y <= 760)
                }
            }
        }
    }


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
        framed.up = pose.up
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
        framed.up = pose.up
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

    @Test("framing repairs an up vector parallel to the view direction")
    func framingRepairsParallelUpVector() {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 5, 0),
                                  target: .zero,
                                  up: SIMD3<Float>(0, 1, 0),
                                  fovYRadians: .pi / 3,
                                  near: 0.1,
                                  far: 100)
        let pose = EditorViewportFraming.pose(camera: camera,
                                              boundsMin: SIMD3<Float>(-1, -1, -1),
                                              boundsMax: SIMD3<Float>(1, 1, 1))
        let forward = simd_normalize(pose.target - pose.eye)

        #expect(pose.up.x.isFinite && pose.up.y.isFinite && pose.up.z.isFinite)
        #expect(abs(simd_length(pose.up) - 1) < 1e-5)
        #expect(simd_length(simd_cross(forward, pose.up)) > 0.1)

        var framed = camera
        framed.eye = pose.eye
        framed.target = pose.target
        framed.up = pose.up
        #expect(EditorViewportProjection(
            camera: framed,
            frame: ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        ) != nil)
    }

    @Test("framing turns non-finite bounds into a safe finite pose")
    func framingRepairsNonFiniteBounds() {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, 5), target: .zero)
        let pose = EditorViewportFraming.pose(camera: camera,
                                              boundsMin: SIMD3<Float>(.nan, -.infinity, 1),
                                              boundsMax: SIMD3<Float>(.infinity, 2, .nan))

        #expect(pose.eye.x.isFinite && pose.eye.y.isFinite && pose.eye.z.isFinite)
        #expect(pose.target == .zero)
        #expect(simd_distance(pose.eye, pose.target) > 0)
    }
}
