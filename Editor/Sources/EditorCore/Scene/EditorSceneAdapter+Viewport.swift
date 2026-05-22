import Foundation
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import IntentRuntime
import RenderBackend
import SceneRuntime
import SIMDCompat

extension EditorSceneAdapter {

    // MARK: - Picking

    /// 鎶婅鍙ｅ厜鏍囧潗鏍囨姇鎴愪笘鐣屽皠绾匡紝瀵规墍鏈夋湁娓叉煋瀹炰緥鐨勫疄浣撳仛 OBB 鍛戒腑娴嬭瘯锛?
    /// 鍙栨渶杩戝懡涓€侽BB 鐢ㄣ€寀nit cube ([-1,1]^3) 脳 瀹炰緥 world transform銆嶈繎浼硷紝
    /// 涓庢覆鏌撶 mesh 褰掍竴鍖栦繚鎸佷竴鑷达紱涓嶄緷璧?collider锛岀函娓叉煋缃戞牸涔熻兘閫変腑銆?
    /// 鑻ユ病鏈夊懡涓覆鏌撳疄渚嬶紝鍐嶅洖閫€鍒?collider raycast 鍏滃簳锛堝甫 collider 鐨勯殣钘忎綋锛夈€?
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

    /// 杩斿洖涓庡睆骞曠煩褰㈢浉浜ょ殑瀹炰綋闆嗗悎銆傜敤浜庤鍙ｆ閫夈€?
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

    /// 杩斿洖娓叉煋瀹炰緥涓栫晫 AABB锛屼緵 wireframe overlay 缁樺埗銆?
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

    /// 杩斿洖鐪熷疄 mesh 杈圭嚎锛堝凡鍙樻崲鍒颁笘鐣岀┖闂达級锛岀敤浜?viewport wireframe overlay銆?
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
        guard let projection = EditorViewportProjection(camera: currentRenderCamera(), frame: frame) else {
            return nil
        }
        let ray = projection.cursorRay(x: cursorX, y: cursorY)
        return ViewportRay(origin: ray.origin, direction: ray.direction)
    }

    private func projectToViewport(_ world: SIMD3<Float>,
                                   in frame: ViewportScreenFrame) -> (x: Float, y: Float)? {
        EditorViewportProjection(camera: currentRenderCamera(), frame: frame)?.project(world)
    }

    // MARK: - Selection helpers

    /// 璁╂椿鍔ㄧ浉鏈虹粫閫変腑瀹炰綋涓栫晫鍧愭爣閲嶆柊鏋勫浘锛氫繚鎸?eye-target 鏂瑰悜 / 璺濈涓嶅彉锛?
    /// 鎶?target 鏀惧埌瀹炰綋涓娿€佸钩绉?eye 鍚岃窛绂汇€傝窛绂昏繃杩戞椂鎸夊悎鐞嗚寖鍥村洖閫€銆?
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

    /// 鐩存帴閿€姣佸疄浣擄紱閫夋嫨鐘舵€佺敱璋冪敤鏂硅礋璐ｆ竻鐞嗐€?
    @discardableResult
    public func deleteEntity(_ rawID: UInt64) -> Bool {
        guard makeEntityID(rawID) != nil else { return false }
        return applySceneTransaction(intentVerb: "scene.delete_entity",
                                     summary: "Delete entity",
                                     targetRawIDs: [rawID],
                                     mutations: [.deleteEntity(entityID: rawID)]) != nil
    }

    /// 娴呭鍒讹細澶嶅埗鍚嶅瓧 / kind / 鏈湴鐭╅樀 / 娓叉煋缃戞牸 / collider / rigid body / camera銆?
    /// 涓嶅鍒跺瓙鑺傜偣锛涙柊瀹炰綋闄勫湪鍘熺埗鑺傜偣涓嬨€傝繑鍥炴柊瀹炰綋 raw ID銆?
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

    /// 鐢ㄥ睆骞曞儚绱?delta 鎺у埗娲诲姩鐩告満缁?target 鐞冮潰鏃嬭浆銆?
    /// 涓庢棫 Editor backend 涓€鑷达細delta 鐩存帴涔?`orbit_sensitivity = 0.01`銆?
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

    /// 鍦ㄧ浉鏈哄彸 / 涓婃柟鍚戜笂骞崇Щ eye 涓?target锛屼繚鎸佽绾挎柟鍚戜笉鍙樸€?
    /// dx / dy 鏄睆骞曞儚绱狅紝璺濈瓒婅繙骞崇Щ瓒婂揩锛屼笌 Blender / Unity 琛屼负涓€鑷淬€?
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

    /// 婊氳疆缂╂斁锛歠actor < 1 鎷夎繎锛? 1 鎺ㄨ繙銆傛妸 eye 娌?(eye - target) 鏂瑰悜缂╂斁銆?
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

    /// 鐩存帴瑕嗙洊鐩告満瀹炰綋鐨?eye锛堝啓鍏?LocalTransform 鐨勫钩绉诲垪锛夊拰 CameraComponent.target銆?
    /// 淇濇寔鍘?LocalTransform 鐨勬棆杞?/ 缂╂斁閮ㄥ垎锛屽洜涓虹浉鏈虹殑鏂瑰悜鐢?target 鍗曠嫭琛ㄨ揪銆?
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
