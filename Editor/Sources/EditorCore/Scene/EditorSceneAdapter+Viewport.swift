import Foundation
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import IntentRuntime
import RenderBackend
import SceneRuntime
import simd

extension EditorSceneAdapter {

    // MARK: - Picking

    /// 把视口光标坐标投成世界射线，对所有有渲染实例的实体做 OBB 命中测试，
    /// 取最近命中。OBB 用「unit cube ([-1,1]^3) × 实例 world transform」近似，
    /// 与渲染端 mesh 归一化保持一致；不依赖 collider，纯渲染网格也能选中。
    /// 若没有命中渲染实例，再回退到 collider raycast 兜底（带 collider 的隐藏体）。
    public func pickEntity(cursorX: Float,
                           cursorY: Float,
                           in frame: ViewportScreenFrame) -> UInt64? {
        guard let ray = viewportRay(cursorX: cursorX, cursorY: cursorY, in: frame) else {
            return nil
        }
        if let hit = pickRenderedEntity(ray: ray) {
            return hit
        }
        let query = SceneRaycastQuery(origin: ray.origin,
                                      direction: ray.direction,
                                      maxDistance: 10_000,
                                      includeTriggers: true)
        return scene.raycast(query)?.entity.rawValue
    }

    private func pickRenderedEntity(ray: ViewportRay) -> UInt64? {
        guard let extracted = scene.extractedRenderScene else { return nil }
        var bestT: Float = .greatestFiniteMagnitude
        var bestEntity: EntityID?
        for (idx, entity) in extracted.instanceEntities.enumerated() {
            let inst = extracted.scene.instances[idx]
            let local = MeshBoundsRegistry.shared.bounds(for: inst.meshIndex)
                       ?? (min: SIMD3<Float>(-0.5, -0.5, -0.5),
                           max: SIMD3<Float>(0.5, 0.5, 0.5))
            let aabb = worldAABB(forLocalMin: local.min,
                                 localMax: local.max,
                                 transformedBy: inst.transform)
            if let t = rayAABBIntersect(origin: ray.origin,
                                        direction: ray.direction,
                                        aabbMin: aabb.min,
                                        aabbMax: aabb.max),
               t > 0, t < bestT
            {
                bestT = t
                bestEntity = entity
            }
        }
        return bestEntity?.rawValue
    }

    /// 返回与屏幕矩形相交的实体集合。用于视口框选。
    public func pickEntities(in screenRect: UIRect,
                             frame: ViewportScreenFrame) -> Set<UInt64> {
        guard let extracted = scene.extractedRenderScene else { return [] }
        let rectMinX = min(screenRect.x, screenRect.x + screenRect.width)
        let rectMaxX = max(screenRect.x, screenRect.x + screenRect.width)
        let rectMinY = min(screenRect.y, screenRect.y + screenRect.height)
        let rectMaxY = max(screenRect.y, screenRect.y + screenRect.height)

        var hits = Set<UInt64>()
        for (idx, entity) in extracted.instanceEntities.enumerated() {
            let inst = extracted.scene.instances[idx]
            let local = MeshBoundsRegistry.shared.bounds(for: inst.meshIndex)
                       ?? (min: SIMD3<Float>(-0.5, -0.5, -0.5),
                           max: SIMD3<Float>(0.5, 0.5, 0.5))
            let corners = worldAABBCorners(localMin: local.min,
                                           localMax: local.max,
                                           transformedBy: inst.transform)
            var sx0: Float = .greatestFiniteMagnitude
            var sy0: Float = .greatestFiniteMagnitude
            var sx1: Float = -.greatestFiniteMagnitude
            var sy1: Float = -.greatestFiniteMagnitude
            var hasProjectedCorner = false
            for corner in corners {
                guard let s = projectToViewport(corner, in: frame) else { continue }
                hasProjectedCorner = true
                sx0 = min(sx0, s.x)
                sy0 = min(sy0, s.y)
                sx1 = max(sx1, s.x)
                sy1 = max(sy1, s.y)
            }
            guard hasProjectedCorner else { continue }
            let overlapX = sx1 >= rectMinX && sx0 <= rectMaxX
            let overlapY = sy1 >= rectMinY && sy0 <= rectMaxY
            if overlapX && overlapY {
                hits.insert(entity.rawValue)
            }
        }
        return hits
    }

    /// 返回渲染实例世界 AABB，供 wireframe overlay 绘制。
    public func viewportWorldBounds() -> [(entityID: UInt64, min: SIMD3<Float>, max: SIMD3<Float>)] {
        guard let extracted = scene.extractedRenderScene else { return [] }
        return extracted.instanceEntities.enumerated().map { idx, entity in
            let inst = extracted.scene.instances[idx]
            let local = MeshBoundsRegistry.shared.bounds(for: inst.meshIndex)
                       ?? (min: SIMD3<Float>(-0.5, -0.5, -0.5),
                           max: SIMD3<Float>(0.5, 0.5, 0.5))
            let aabb = worldAABB(forLocalMin: local.min,
                                 localMax: local.max,
                                 transformedBy: inst.transform)
            return (entityID: entity.rawValue, min: aabb.min, max: aabb.max)
        }
    }

    /// 返回真实 mesh 边线（已变换到世界空间），用于 viewport wireframe overlay。
    public func viewportWireframeLines(maxEdgesPerMesh: Int = 2_048)
        -> [(entityID: UInt64, a: SIMD3<Float>, b: SIMD3<Float>)] {
        guard let extracted = scene.extractedRenderScene else { return [] }
        var lines: [(entityID: UInt64, a: SIMD3<Float>, b: SIMD3<Float>)] = []
        lines.reserveCapacity(extracted.scene.instances.count * 256)

        for (idx, entity) in extracted.instanceEntities.enumerated() {
            let instance = extracted.scene.instances[idx]
            guard let edges = MeshWireframeRegistry.shared.edges(for: instance.meshIndex),
                  !edges.isEmpty
            else {
                continue
            }
            let stride = max(1, edges.count / max(maxEdgesPerMesh, 1))
            var edgeIndex = 0
            while edgeIndex < edges.count {
                let edge = edges[edgeIndex]
                let wa = instance.transform * SIMD4<Float>(edge.a, 1)
                let wb = instance.transform * SIMD4<Float>(edge.b, 1)
                lines.append((entityID: entity.rawValue,
                              a: SIMD3<Float>(wa.x, wa.y, wa.z),
                              b: SIMD3<Float>(wb.x, wb.y, wb.z)))
                edgeIndex += stride
            }
        }
        return lines
    }

    private func worldAABB(forLocalMin lo: SIMD3<Float>,
                           localMax hi: SIMD3<Float>,
                           transformedBy m: simd_float4x4)
        -> (min: SIMD3<Float>, max: SIMD3<Float>)
    {
        var wlo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var whi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let xs: [Float] = [lo.x, hi.x]
        let ys: [Float] = [lo.y, hi.y]
        let zs: [Float] = [lo.z, hi.z]
        for x in xs {
            for y in ys {
                for z in zs {
                    let p = m * SIMD4<Float>(x, y, z, 1)
                    let v = SIMD3<Float>(p.x, p.y, p.z)
                    wlo = simd_min(wlo, v)
                    whi = simd_max(whi, v)
                }
            }
        }
        return (wlo, whi)
    }

    private func worldAABBCorners(localMin lo: SIMD3<Float>,
                                  localMax hi: SIMD3<Float>,
                                  transformedBy m: simd_float4x4) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(8)
        let xs: [Float] = [lo.x, hi.x]
        let ys: [Float] = [lo.y, hi.y]
        let zs: [Float] = [lo.z, hi.z]
        for x in xs {
            for y in ys {
                for z in zs {
                    let p = m * SIMD4<Float>(x, y, z, 1)
                    points.append(SIMD3<Float>(p.x, p.y, p.z))
                }
            }
        }
        return points
    }

    private func rayAABBIntersect(origin: SIMD3<Float>,
                                  direction: SIMD3<Float>,
                                  aabbMin: SIMD3<Float>,
                                  aabbMax: SIMD3<Float>) -> Float? {
        var tmin: Float = -.greatestFiniteMagnitude
        var tmax: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = origin[axis], d = direction[axis]
            let lo = aabbMin[axis], hi = aabbMax[axis]
            if abs(d) < 1e-6 {
                if o < lo || o > hi { return nil }
                continue
            }
            let inv = 1.0 / d
            var t1 = (lo - o) * inv
            var t2 = (hi - o) * inv
            if t1 > t2 { swap(&t1, &t2) }
            tmin = max(tmin, t1)
            tmax = min(tmax, t2)
            if tmin > tmax { return nil }
        }
        return tmin > 0 ? tmin : (tmax > 0 ? tmax : nil)
    }

    private struct ViewportRay { var origin: SIMD3<Float>; var direction: SIMD3<Float> }

    private func viewportRay(cursorX: Float,
                             cursorY: Float,
                             in frame: ViewportScreenFrame) -> ViewportRay? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let cam = currentRenderCamera()
        let u = (cursorX - frame.x) / frame.width
        let v = (cursorY - frame.y) / frame.height
        let ndcX = 2 * u - 1
        let ndcY = 1 - 2 * v

        let forward = simd_normalize(cam.target - cam.eye)
        let rightRaw = simd_cross(forward, cam.up)
        guard simd_length(rightRaw) > 1e-5 else { return nil }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))
        let aspect = frame.width / frame.height
        let tanHalfFov = tanf(cam.fovYRadians * 0.5)
        let rightOffset = right * (ndcX * aspect * tanHalfFov)
        let upOffset = up * (ndcY * tanHalfFov)
        let dir = simd_normalize(forward + rightOffset + upOffset)
        return ViewportRay(origin: cam.eye, direction: dir)
    }

    private func projectToViewport(_ world: SIMD3<Float>,
                                   in frame: ViewportScreenFrame) -> (x: Float, y: Float)? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let cam = currentRenderCamera()
        let forwardRaw = cam.target - cam.eye
        guard simd_length(forwardRaw) > 1e-5 else { return nil }
        let forward = simd_normalize(forwardRaw)
        let rightRaw = simd_cross(forward, cam.up)
        guard simd_length(rightRaw) > 1e-5 else { return nil }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))

        let view = lookAt(eye: cam.eye, target: cam.target, up: up)
        let proj = perspective(fovYRadians: cam.fovYRadians,
                               aspect: frame.width / frame.height,
                               near: cam.near,
                               far: cam.far)
        let clip = proj * (view * SIMD4<Float>(world, 1))
        guard clip.w > 1e-4 else { return nil }
        let ndcX = clip.x / clip.w
        let ndcY = clip.y / clip.w
        let x = frame.x + (ndcX * 0.5 + 0.5) * frame.width
        let y = frame.y + (1 - (ndcY * 0.5 + 0.5)) * frame.height
        return (x, y)
    }

    private func lookAt(eye: SIMD3<Float>,
                        target: SIMD3<Float>,
                        up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(s.x, u.x, -f.x, 0)
        m.columns.1 = SIMD4<Float>(s.y, u.y, -f.y, 0)
        m.columns.2 = SIMD4<Float>(s.z, u.z, -f.z, 0)
        m.columns.3 = SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        return m
    }

    private func perspective(fovYRadians: Float,
                             aspect: Float,
                             near: Float,
                             far: Float) -> simd_float4x4 {
        let f = 1 / tanf(fovYRadians * 0.5)
        var m = simd_float4x4()
        m.columns.0 = SIMD4<Float>(f / aspect, 0, 0, 0)
        m.columns.1 = SIMD4<Float>(0, f, 0, 0)
        m.columns.2 = SIMD4<Float>(0, 0, far / (near - far), -1)
        m.columns.3 = SIMD4<Float>(0, 0, (far * near) / (near - far), 0)
        return m
    }

    // MARK: - Selection helpers

    /// 让活动相机绕选中实体世界坐标重新构图：保持 eye-target 方向 / 距离不变，
    /// 把 target 放到实体上、平移 eye 同距离。距离过近时按合理范围回退。
    public func frameEntity(_ rawID: UInt64) {
        guard let target = entityWorldPosition(rawID) else { return }
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        var offset = cam.eye - cam.target
        let dist = simd_length(offset)
        let safeDist = dist < 0.5 ? 4.0 : dist
        if dist < 1e-4 {
            offset = SIMD3<Float>(0, 1.5, 4)
        } else {
            offset = simd_normalize(offset) * Float(safeDist)
        }
        let newEye = target + offset
        setCameraEye(camID, eye: newEye, target: target)
    }

    // MARK: - Entity ops

    /// 直接销毁实体；选择状态由调用方负责清理。
    @discardableResult
    public func deleteEntity(_ rawID: UInt64) -> Bool {
        guard makeEntityID(rawID) != nil else { return false }
        return applySceneTransaction(intentVerb: "scene.delete_entity",
                                     summary: "Delete entity",
                                     targetRawIDs: [rawID],
                                     mutations: [.deleteEntity(entityID: rawID)]) != nil
    }

    /// 浅复制：复制名字 / kind / 本地矩阵 / 渲染网格 / collider / rigid body / camera。
    /// 不复制子节点；新实体附在原父节点下。返回新实体 raw ID。
    @discardableResult
    public func duplicateEntity(_ rawID: UInt64) -> UInt64? {
        guard let src = makeEntityID(rawID), scene.contains(src) else { return nil }
        let result = applySceneTransaction(intentVerb: "scene.duplicate_entity",
                                           summary: "Duplicate entity",
                                           targetRawIDs: [rawID],
                                           mutations: [.duplicateEntity(entityID: rawID)])
        return result?.createdEntityIDs.first
    }

    // MARK: - Camera control

    /// 用屏幕像素 delta 控制活动相机绕 target 球面旋转。
    /// 与旧 Editor backend 一致：delta 直接乘 `orbit_sensitivity = 0.01`。
    public func orbitCamera(deltaScreenX dx: Float,
                            deltaScreenY dy: Float,
                            in frame: ViewportScreenFrame) {
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        let forwardRaw = cam.target - cam.eye
        let distance = simd_length(forwardRaw)
        guard distance > 1e-4 else { return }

        let forward = forwardRaw / distance
        var yaw = atan2f(forward.x, forward.z)
        var pitch = asinf(max(-1, min(1, forward.y)))
        yaw -= dx * 0.01
        pitch = clampPitch(pitch - dy * 0.01)

        let nextForward = forwardFromAngles(yaw: yaw, pitch: pitch)
        let newEye = cam.target - nextForward * distance
        setCameraEye(camID, eye: newEye, target: cam.target, up: SIMD3<Float>(0, 1, 0))
        _ = frame
    }

    /// 在相机右 / 上方向上平移 eye 与 target，保持视线方向不变。
    /// dx / dy 是屏幕像素，距离越远平移越快，与 Blender / Unity 行为一致。
    public func panCamera(deltaScreenX dx: Float,
                          deltaScreenY dy: Float,
                          in frame: ViewportScreenFrame) {
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        let forward = simd_normalize(cam.target - cam.eye)
        let rightRaw = simd_cross(forward, cam.up)
        guard simd_length(rightRaw) > 1e-5 else { return }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))
        let dist = max(0.5, simd_length(cam.eye - cam.target))
        let factors = panSpeedFactors(width: frame.width, height: frame.height)
        let move = -right * (dx * factors.x * dist * 0.01)
                 + up * (dy * factors.y * dist * 0.01)
        let newEye = cam.eye + move
        let newTarget = cam.target + move
        setCameraEye(camID, eye: newEye, target: newTarget)
    }

    /// Alt+RMB dolly: move the orbit eye along the current view vector while keeping the target stable.
    public func dollyCamera(deltaScreenY dy: Float) {
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        let forwardRaw = cam.target - cam.eye
        let dist = simd_length(forwardRaw)
        guard dist > 1e-4 else { return }
        let forward = forwardRaw / dist
        let step = -dy * 1.2 * 0.01 * zoomSpeed(distance: dist)
        let newDist = max(0.2, min(500, dist - step))
        let newEye = cam.target - forward * newDist
        setCameraEye(camID, eye: newEye, target: cam.target)
    }

    /// RMB freelook: rotate around the eye and optionally move with WASDQE.
    public func freelookCamera(deltaScreenX dx: Float,
                               deltaScreenY dy: Float,
                               pressedScancodes: Set<UInt32>,
                               modifiers: KeyModifiers,
                               deltaTime: Float = 1.0 / 60.0) {
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        var forward = cam.target - cam.eye
        let focusDistance = max(0.5, simd_length(forward))
        guard focusDistance > 1e-4 else { return }
        forward = simd_normalize(forward)

        let worldUp = SIMD3<Float>(0, 1, 0)
        let yaw = simd_quatf(angle: -dx * 0.008, axis: worldUp)
        var right = simd_cross(forward, cam.up)
        if simd_length(right) < 1e-5 {
            right = simd_cross(forward, worldUp)
        }
        right = simd_normalize(right)
        let pitch = simd_quatf(angle: -dy * 0.008, axis: right)
        var nextForward = simd_normalize(yaw.act(pitch.act(forward)))
        if abs(simd_dot(nextForward, worldUp)) > 0.985 {
            nextForward = simd_normalize(yaw.act(forward))
        }
        right = simd_normalize(simd_cross(nextForward, worldUp))
        let up = simd_normalize(simd_cross(right, nextForward))

        var move = SIMD3<Float>(repeating: 0)
        if pressedScancodes.contains(26) { move += nextForward } // W
        if pressedScancodes.contains(22) { move -= nextForward } // S
        if pressedScancodes.contains(7)  { move += right }       // D
        if pressedScancodes.contains(4)  { move -= right }       // A
        if pressedScancodes.contains(8)  { move += up }          // E
        if pressedScancodes.contains(20) { move -= up }          // Q
        let boost: Float = modifiers.contains(.shift) ? 3.5 : 1
        let speed: Float = 6.0 * boost * max(deltaTime, 1.0 / 240.0)
        let translation = simd_length(move) > 1e-5 ? simd_normalize(move) * speed : .zero

        let newEye = cam.eye + translation
        let newTarget = newEye + nextForward * focusDistance
        setCameraEye(camID, eye: newEye, target: newTarget, up: up)
    }

    /// 滚轮缩放：factor < 1 拉近，> 1 推远。把 eye 沿 (eye - target) 方向缩放。
    public func zoomCamera(factor: Float) {
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        let offset = cam.eye - cam.target
        let r = simd_length(offset)
        if r < 1e-4 { return }
        let newR = max(0.2, min(500, r * factor))
        let newEye = cam.target + simd_normalize(offset) * newR
        setCameraEye(camID, eye: newEye, target: cam.target)
    }

    /// ViewCube axis snap. `axis` is the desired camera forward direction in world space.
    public func lookAlongAxis(_ axis: SIMD3<Float>) {
        guard let camID = activeCameraEntityRaw() else { return }
        let cam = currentRenderCamera()
        let len = simd_length(axis)
        guard len > 1e-5 else { return }
        let forward = axis / len
        let dist = max(0.5, simd_length(cam.eye - cam.target))
        let newEye = cam.target - forward * dist
        let up = viewUp(forForward: forward)
        setCameraEye(camID, eye: newEye, target: cam.target, up: up)
    }

    // MARK: - Internal

    private func activeCameraEntityRaw() -> EntityID? {
        scene.extractedRenderScene?.activeCameraEntity
    }

    /// 直接覆盖相机实体的 eye（写入 LocalTransform 的平移列）和 CameraComponent.target。
    /// 保持原 LocalTransform 的旋转 / 缩放部分，因为相机的方向由 target 单独表达。
    private func setCameraEye(_ entity: EntityID,
                              eye: SIMD3<Float>,
                              target: SIMD3<Float>,
                              up: SIMD3<Float>? = nil) {
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix.columns.3 = SIMD4<Float>(eye.x, eye.y, eye.z, 1)
        _ = applySceneTransaction(intentVerb: "scene.set_camera_pose",
                                  summary: "Update camera pose",
                                  targetRawIDs: [entity.rawValue],
                                  mutations: [.setCameraPose(entityID: entity.rawValue,
                                                             localTransform: local,
                                                             target: target,
                                                             up: up)])
    }

    private func viewUp(forForward forward: SIMD3<Float>) -> SIMD3<Float> {
        let worldUp = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(forward, worldUp)) < 0.92 {
            return worldUp
        }
        return forward.y < 0 ? SIMD3<Float>(0, 0, -1) : SIMD3<Float>(0, 0, 1)
    }

    private func clampPitch(_ value: Float) -> Float {
        max(-Float.pi * 0.5 + 0.05, min(Float.pi * 0.5 - 0.05, value))
    }

    private func forwardFromAngles(yaw: Float, pitch: Float) -> SIMD3<Float> {
        let cp = cosf(pitch)
        return simd_normalize(SIMD3<Float>(sinf(yaw) * cp,
                                           sinf(pitch),
                                           cosf(yaw) * cp))
    }

    private func panSpeedFactors(width: Float, height: Float) -> (x: Float, y: Float) {
        let widthK = min(width / 1000.0, 2.4)
        let heightK = min(height / 1000.0, 2.4)
        return (
            0.0366 * widthK * widthK - 0.1778 * widthK + 0.3021,
            0.0366 * heightK * heightK - 0.1778 * heightK + 0.3021
        )
    }

    private func zoomSpeed(distance: Float) -> Float {
        let scaled = max(distance * 0.2, 0)
        return min(scaled * scaled, 100)
    }

    private func makeEntityID(_ rawID: UInt64) -> EntityID? {
        EntityID(
            index: UInt32(rawID & 0xFFFF_FFFF),
            generation: UInt32(rawID >> 32)
        )
    }
}
