import Foundation
import GuavaUICompose
import RenderBackend
import SceneRuntime
import simd

/// 视口内 3D 操纵器（gizmo）的拖动状态与命中测试，覆盖
/// translate / rotate / scale 三种模式。
///
/// ViewportPanel 每帧调用 `updateSnapshot` 写入摄像机、屏幕矩形、
/// 选中实体世界位置与本地矩阵；指针/绘制回调通过
/// `EditorGizmoController.shared` 命中测试并产出新的 LocalTransform。
public final class EditorGizmoController: @unchecked Sendable {

    public static let shared = EditorGizmoController()

    public enum Mode: Sendable {
        case translate
        case rotate
        case scale
    }

    public enum Axis: Int, Sendable, CaseIterable {
        case x
        case y
        case z

        public var worldDirection: SIMD3<Float> {
            switch self {
            case .x: return SIMD3<Float>(1, 0, 0)
            case .y: return SIMD3<Float>(0, 1, 0)
            case .z: return SIMD3<Float>(0, 0, 1)
            }
        }

        public var color: SIMD4<Float> {
            switch self {
            case .x: return SIMD4<Float>(0.95, 0.27, 0.34, 1)
            case .y: return SIMD4<Float>(0.36, 0.86, 0.41, 1)
            case .z: return SIMD4<Float>(0.34, 0.58, 0.95, 1)
            }
        }

        /// 在该轴对应的旋转平面（即垂直于该轴的平面）里的两个正交基向量，
        /// 用来在世界空间画圆 / 计算角度。
        public var planeBasis: (SIMD3<Float>, SIMD3<Float>) {
            switch self {
            case .x: return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
            case .y: return (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0))
            case .z: return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
            }
        }
    }

    public enum Plane: Sendable, CaseIterable {
        case xy, yz, zx

        /// 平面里的两个正交世界基向量（U, V）。
        public var basis: (SIMD3<Float>, SIMD3<Float>) {
            switch self {
            case .xy: return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
            case .yz: return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
            case .zx: return (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0))
            }
        }

        /// 平面法向量（指向另一根世界轴）。
        public var normal: SIMD3<Float> {
            switch self {
            case .xy: return SIMD3<Float>(0, 0, 1)
            case .yz: return SIMD3<Float>(1, 0, 0)
            case .zx: return SIMD3<Float>(0, 1, 0)
            }
        }

        /// 平面手柄的填充色：取另一根世界轴的颜色，便于和轴线区分。
        public var color: SIMD4<Float> {
            switch self {
            case .xy: return Axis.z.color
            case .yz: return Axis.x.color
            case .zx: return Axis.y.color
            }
        }
    }

    public struct Snapshot {
        public var mode: Mode
        public var camera: RenderCamera
        public var frame: ViewportScreenFrame
        public var drawableWidth: Float
        public var drawableHeight: Float
        public var entityID: UInt64
        public var entityWorldPosition: SIMD3<Float>
        public var entityLocalMatrix: simd_float4x4
        public var parentWorldMatrix: simd_float4x4
        public var axisLength: Float

        public init(mode: Mode,
                    camera: RenderCamera,
                    frame: ViewportScreenFrame,
                    drawableWidth: Float,
                    drawableHeight: Float,
                    entityID: UInt64,
                    entityWorldPosition: SIMD3<Float>,
                    entityLocalMatrix: simd_float4x4,
                    parentWorldMatrix: simd_float4x4,
                    axisLength: Float) {
            self.mode = mode
            self.camera = camera
            self.frame = frame
            self.drawableWidth = drawableWidth
            self.drawableHeight = drawableHeight
            self.entityID = entityID
            self.entityWorldPosition = entityWorldPosition
            self.entityLocalMatrix = entityLocalMatrix
            self.parentWorldMatrix = parentWorldMatrix
            self.axisLength = axisLength
        }
    }

    public struct ActiveDrag {
        public var entityID: UInt64
        public var mode: Mode
        public var axis: Axis
        public var plane: Plane?
        public var startEntityWorldPosition: SIMD3<Float>
        public var startEntityLocalMatrix: simd_float4x4
        public var startEntityWorldMatrix: simd_float4x4
        public var parentWorldMatrix: simd_float4x4
        public var parentInverseMatrix: simd_float4x4
        // translate / scale: 起始的轴向参数（射线-轴最近点参数 t）
        public var startAxisParam: Float
        // rotate: 起始角度（在 axis 旋转平面里的极角，弧度）
        public var startAngle: Float
        // planeTranslate: 起始时光标在平面上的世界命中点
        public var startPlaneHit: SIMD3<Float>
    }

    private let lock = NSLock()
    private var _snapshot: Snapshot?
    private var _activeDrag: ActiveDrag?

    public var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    public var activeDrag: ActiveDrag? {
        lock.lock(); defer { lock.unlock() }
        return _activeDrag
    }

    public func updateSnapshot(_ snapshot: Snapshot?) {
        lock.lock(); defer { lock.unlock() }
        _snapshot = snapshot
        if let drag = _activeDrag,
           drag.entityID != snapshot?.entityID || drag.mode != snapshot?.mode {
            _activeDrag = nil
        }
    }

    public func clearDrag() {
        lock.lock(); defer { lock.unlock() }
        _activeDrag = nil
    }

    /// 统一构造 ActiveDrag，把 parent / world 矩阵和起始世界矩阵一次性算好，
    /// 便于后续 update 把世界变换换算回本地空间。
    private func makeDrag(snap: Snapshot,
                          axis: Axis,
                          plane: Plane?,
                          startAxisParam: Float,
                          startAngle: Float,
                          startPlaneHit: SIMD3<Float>) -> ActiveDrag {
        let parentWorld = snap.parentWorldMatrix
        let parentInverse = simd_inverse(parentWorld)
        let startWorldMatrix = parentWorld * snap.entityLocalMatrix
        return ActiveDrag(
            entityID: snap.entityID,
            mode: snap.mode,
            axis: axis,
            plane: plane,
            startEntityWorldPosition: snap.entityWorldPosition,
            startEntityLocalMatrix: snap.entityLocalMatrix,
            startEntityWorldMatrix: startWorldMatrix,
            parentWorldMatrix: parentWorld,
            parentInverseMatrix: parentInverse,
            startAxisParam: startAxisParam,
            startAngle: startAngle,
            startPlaneHit: startPlaneHit
        )
    }

    /// 命中测试：在屏幕坐标 `(x, y)` 处尝试命中某个轴。命中阈值
    /// `screenTolerance` 单位为像素（rotate 模式下在圆周附近的容差）。
    public func beginDrag(cursorX: Float,
                          cursorY: Float,
                          screenTolerance: Float = 8) -> ActiveDrag? {
        lock.lock()
        let snapshotCopy = _snapshot
        lock.unlock()

        guard let snap = snapshotCopy else { return nil }
        guard let projector = ScreenProjector(snap) else { return nil }

        switch snap.mode {
        case .translate:
            // 平面手柄优先于轴：手柄在原点偏移处，命中区域比轴线小，
            // 但与轴线不重叠，先尝试更精准。
            if let drag = beginPlaneTranslateDrag(
                snap: snap,
                projector: projector,
                cursorX: cursorX, cursorY: cursorY)
            {
                return drag
            }
            return beginAxisDrag(snap: snap,
                                 projector: projector,
                                 cursorX: cursorX, cursorY: cursorY,
                                 screenTolerance: screenTolerance)
        case .scale:
            return beginAxisDrag(snap: snap,
                                 projector: projector,
                                 cursorX: cursorX, cursorY: cursorY,
                                 screenTolerance: screenTolerance)
        case .rotate:
            return beginRotateDrag(snap: snap,
                                   projector: projector,
                                   cursorX: cursorX, cursorY: cursorY,
                                   screenTolerance: screenTolerance)
        }
    }

    /// 拖动中：根据当前光标位置返回新的 LocalTransform 矩阵。
    /// 返回 `nil` 表示当前光标不再可解（例如视线与轴近平行）。
    public func updateDrag(cursorX: Float, cursorY: Float) -> simd_float4x4? {
        lock.lock()
        let snapshotCopy = _snapshot
        let dragCopy = _activeDrag
        lock.unlock()

        guard let snap = snapshotCopy, let drag = dragCopy else { return nil }
        guard let projector = ScreenProjector(snap) else { return nil }
        guard let ray = projector.cursorRay(x: cursorX, y: cursorY) else { return nil }

        switch drag.mode {
        case .translate:
            if drag.plane != nil {
                return updatePlaneTranslateMatrix(snap: snap, drag: drag, ray: ray)
            }
            return updateTranslateMatrix(snap: snap, drag: drag, ray: ray)
        case .scale:
            return updateScaleMatrix(snap: snap, drag: drag, ray: ray)
        case .rotate:
            return updateRotateMatrix(snap: snap, drag: drag, ray: ray)
        }
    }

    // MARK: - Translate / Scale

    private func beginAxisDrag(snap: Snapshot,
                               projector: ScreenProjector,
                               cursorX: Float, cursorY: Float,
                               screenTolerance: Float) -> ActiveDrag? {
        guard let originScreen = projector.project(snap.entityWorldPosition) else { return nil }

        var bestAxis: Axis?
        var bestDistance: Float = .infinity
        for axis in Axis.allCases {
            let tip = snap.entityWorldPosition + axis.worldDirection * snap.axisLength
            guard let tipScreen = projector.project(tip) else { continue }
            let distance = pointToSegmentDistance(
                px: cursorX, py: cursorY,
                ax: originScreen.x, ay: originScreen.y,
                bx: tipScreen.x, by: tipScreen.y
            )
            if distance < bestDistance {
                bestDistance = distance
                bestAxis = axis
            }
        }

        guard let axis = bestAxis, bestDistance <= screenTolerance else { return nil }

        guard let ray = projector.cursorRay(x: cursorX, y: cursorY) else { return nil }
        guard let startParam = closestPointOnAxis(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            axisOrigin: snap.entityWorldPosition,
            axisDir: axis.worldDirection
        ) else { return nil }

        let drag = makeDrag(snap: snap,
                            axis: axis,
                            plane: nil,
                            startAxisParam: startParam,
                            startAngle: 0,
                            startPlaneHit: .zero)
        lock.lock(); _activeDrag = drag; lock.unlock()
        return drag
    }

    private func updateTranslateMatrix(snap: Snapshot,
                                       drag: ActiveDrag,
                                       ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard let currentParam = closestPointOnAxis(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            axisOrigin: drag.startEntityWorldPosition,
            axisDir: drag.axis.worldDirection
        ) else { return nil }

        let delta = currentParam - drag.startAxisParam
        let newWorldPos = drag.startEntityWorldPosition + drag.axis.worldDirection * delta
        var worldMatrix = drag.startEntityWorldMatrix
        worldMatrix.columns.3 = SIMD4<Float>(newWorldPos, 1)
        return drag.parentInverseMatrix * worldMatrix
    }

    private func updateScaleMatrix(snap: Snapshot,
                                   drag: ActiveDrag,
                                   ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard let currentParam = closestPointOnAxis(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            axisOrigin: drag.startEntityWorldPosition,
            axisDir: drag.axis.worldDirection
        ) else { return nil }

        // 以 axisLength 为参考长度：把光标沿轴的位移映射到缩放因子。
        let referenceLength = max(snap.axisLength, 0.001)
        let delta = currentParam - drag.startAxisParam
        let factor = max(0.01, 1 + delta / referenceLength)

        // 世界轴上的非均匀缩放矩阵： S = I + (factor - 1) * a * aᵀ
        let s = scaleAlongAxisMatrix(factor: factor, axis: drag.axis.worldDirection)
        let worldMatrix = s * drag.startEntityWorldMatrix
        return drag.parentInverseMatrix * worldMatrix
    }

    // MARK: - Plane translate

    /// 平面手柄在世界空间的几何范围：以原点为起点沿 (basisU, basisV) 方向
    /// 各取 `axisLength * 0.15 .. axisLength * 0.45` 形成一个矩形。
    private func planeQuadCorners(snap: Snapshot, plane: Plane) -> [SIMD3<Float>] {
        let (u, v) = plane.basis
        let lo = snap.axisLength * 0.15
        let hi = snap.axisLength * 0.45
        let o = snap.entityWorldPosition
        return [
            o + u * lo + v * lo,
            o + u * hi + v * lo,
            o + u * hi + v * hi,
            o + u * lo + v * hi
        ]
    }

    private func beginPlaneTranslateDrag(snap: Snapshot,
                                         projector: ScreenProjector,
                                         cursorX: Float,
                                         cursorY: Float) -> ActiveDrag? {
        for plane in Plane.allCases {
            let corners = planeQuadCorners(snap: snap, plane: plane)
            // 世界空间四点投到屏幕，做凸四边形点-在-多边形测试。
            var screenCorners: [(Float, Float)] = []
            screenCorners.reserveCapacity(4)
            for c in corners {
                guard let s = projector.project(c) else { screenCorners.removeAll(); break }
                screenCorners.append((s.x, s.y))
            }
            guard screenCorners.count == 4 else { continue }
            guard pointInQuad(px: cursorX, py: cursorY, quad: screenCorners) else { continue }

            // 命中：用 ray-plane 求交得到起始世界点。
            guard let ray = projector.cursorRay(x: cursorX, y: cursorY) else { return nil }
            guard let hit = rayPlaneIntersect(
                rayOrigin: ray.origin,
                rayDir: ray.direction,
                planeOrigin: snap.entityWorldPosition,
                planeNormal: plane.normal
            ) else { return nil }

            let drag = makeDrag(snap: snap,
                                axis: .x,
                                plane: plane,
                                startAxisParam: 0,
                                startAngle: 0,
                                startPlaneHit: hit)
            lock.lock(); _activeDrag = drag; lock.unlock()
            return drag
        }
        return nil
    }

    private func updatePlaneTranslateMatrix(snap: Snapshot,
                                            drag: ActiveDrag,
                                            ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard let plane = drag.plane else { return nil }
        guard let hit = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: drag.startEntityWorldPosition,
            planeNormal: plane.normal
        ) else { return nil }

        let deltaWorld = hit - drag.startPlaneHit
        let newWorldPos = drag.startEntityWorldPosition + deltaWorld
        var worldMatrix = drag.startEntityWorldMatrix
        worldMatrix.columns.3 = SIMD4<Float>(newWorldPos, 1)
        return drag.parentInverseMatrix * worldMatrix
    }

    // MARK: - Rotate

    private func beginRotateDrag(snap: Snapshot,
                                 projector: ScreenProjector,
                                 cursorX: Float, cursorY: Float,
                                 screenTolerance: Float) -> ActiveDrag? {
        // 在三个旋转圆里挑命中的：每个圆采样 N 个点，先在屏幕上找最近点距离。
        struct Candidate { var axis: Axis; var screenDistance: Float; var hitWorld: SIMD3<Float> }
        var best: Candidate?

        let radius = snap.axisLength
        let segments = 64

        for axis in Axis.allCases {
            let (basisU, basisV) = axis.planeBasis
            // 屏幕最近点 + 命中世界点（用相邻段做线性插值的近似已够）
            var prevScreen: (x: Float, y: Float)?
            var prevWorld: SIMD3<Float> = .zero
            for i in 0...segments {
                let t = Float(i) / Float(segments) * 2 * .pi
                let world = snap.entityWorldPosition
                            + (basisU * cosf(t) + basisV * sinf(t)) * radius
                guard let screen = projector.project(world) else {
                    prevScreen = nil; continue
                }
                if let prev = prevScreen {
                    let d = pointToSegmentDistance(
                        px: cursorX, py: cursorY,
                        ax: prev.x, ay: prev.y,
                        bx: screen.x, by: screen.y
                    )
                    if d < (best?.screenDistance ?? .infinity) {
                        // 用线段中点近似命中世界点
                        let midWorld = (prevWorld + world) * 0.5
                        best = Candidate(axis: axis, screenDistance: d, hitWorld: midWorld)
                    }
                }
                prevScreen = screen
                prevWorld = world
            }
        }

        guard let candidate = best, candidate.screenDistance <= screenTolerance else {
            return nil
        }

        // 用真实 ray-平面 求交得到更准的起始角度。
        guard let ray = projector.cursorRay(x: cursorX, y: cursorY) else { return nil }
        let axis = candidate.axis
        let normal = axis.worldDirection
        let hitWorld = rayPlaneIntersect(rayOrigin: ray.origin,
                                         rayDir: ray.direction,
                                         planeOrigin: snap.entityWorldPosition,
                                         planeNormal: normal) ?? candidate.hitWorld
        let (basisU, basisV) = axis.planeBasis
        let v = hitWorld - snap.entityWorldPosition
        let startAngle = atan2f(simd_dot(v, basisV), simd_dot(v, basisU))

        let drag = makeDrag(snap: snap,
                            axis: axis,
                            plane: nil,
                            startAxisParam: 0,
                            startAngle: startAngle,
                            startPlaneHit: .zero)
        lock.lock(); _activeDrag = drag; lock.unlock()
        return drag
    }

    private func updateRotateMatrix(snap: Snapshot,
                                    drag: ActiveDrag,
                                    ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        let normal = drag.axis.worldDirection
        guard let hitWorld = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: drag.startEntityWorldPosition,
            planeNormal: normal
        ) else { return nil }

        let (basisU, basisV) = drag.axis.planeBasis
        let v = hitWorld - drag.startEntityWorldPosition
        let currentAngle = atan2f(simd_dot(v, basisV), simd_dot(v, basisU))
        let deltaAngle = currentAngle - drag.startAngle

        // 世界轴旋转所以 R 左乘到世界矩阵上，
        // 再用父逆转换回本地空间。
        let rotMatrix4 = rotation4x4(angle: deltaAngle, axis: normal)
        let worldMatrix = rotMatrix4 * drag.startEntityWorldMatrix
        return drag.parentInverseMatrix * worldMatrix
    }
}

// MARK: - Projection helpers

public struct ScreenProjector {
    public let viewMatrix: simd_float4x4
    public let projMatrix: simd_float4x4
    public let frame: ViewportScreenFrame
    public let cameraEye: SIMD3<Float>
    public let cameraForward: SIMD3<Float>
    public let cameraRight: SIMD3<Float>
    public let cameraUp: SIMD3<Float>
    public let aspect: Float
    public let tanHalfFov: Float

    public init?(_ snapshot: EditorGizmoController.Snapshot) {
        let frame = snapshot.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let cam = snapshot.camera
        let forwardRaw = cam.target - cam.eye
        guard simd_length(forwardRaw) > 1e-5 else { return nil }
        let forward = simd_normalize(forwardRaw)
        let rightRaw = simd_cross(forward, cam.up)
        guard simd_length(rightRaw) > 1e-5 else { return nil }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))

        let aspect = frame.width / frame.height
        self.viewMatrix = ScreenProjector.lookAt(eye: cam.eye, target: cam.target, up: up)
        self.projMatrix = ScreenProjector.perspective(
            fovYRadians: cam.fovYRadians,
            aspect: aspect,
            near: cam.near,
            far: cam.far
        )
        self.frame = frame
        self.cameraEye = cam.eye
        self.cameraForward = forward
        self.cameraRight = right
        self.cameraUp = up
        self.aspect = aspect
        self.tanHalfFov = tanf(cam.fovYRadians * 0.5)
    }

    public func project(_ worldPoint: SIMD3<Float>) -> (x: Float, y: Float)? {
        let viewSpace = viewMatrix * SIMD4<Float>(worldPoint, 1)
        let clip = projMatrix * viewSpace
        guard clip.w > 1e-4 else { return nil }
        let ndcX = clip.x / clip.w
        let ndcY = clip.y / clip.w
        let sx = frame.x + (ndcX * 0.5 + 0.5) * frame.width
        let sy = frame.y + (1 - (ndcY * 0.5 + 0.5)) * frame.height
        return (sx, sy)
    }

    public func cursorRay(x: Float, y: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let u = (x - frame.x) / frame.width
        let v = (y - frame.y) / frame.height
        let ndcX = 2 * u - 1
        let ndcY = 1 - 2 * v
        let dir = simd_normalize(cameraForward
                                 + cameraRight * (ndcX * aspect * tanHalfFov)
                                 + cameraUp * (ndcY * tanHalfFov))
        return (cameraEye, dir)
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
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

    private static func perspective(fovYRadians: Float,
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
}

private func pointToSegmentDistance(px: Float, py: Float,
                                    ax: Float, ay: Float,
                                    bx: Float, by: Float) -> Float {
    let dx = bx - ax
    let dy = by - ay
    let lenSq = dx * dx + dy * dy
    if lenSq < 1e-4 {
        let ddx = px - ax
        let ddy = py - ay
        return (ddx * ddx + ddy * ddy).squareRoot()
    }
    let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
    let cx = ax + t * dx
    let cy = ay + t * dy
    let ex = px - cx
    let ey = py - cy
    return (ex * ex + ey * ey).squareRoot()
}

private func closestPointOnAxis(rayOrigin: SIMD3<Float>,
                                rayDir: SIMD3<Float>,
                                axisOrigin: SIMD3<Float>,
                                axisDir: SIMD3<Float>) -> Float? {
    let w0 = axisOrigin - rayOrigin
    let a = simd_dot(axisDir, axisDir)
    let b = simd_dot(axisDir, rayDir)
    let c = simd_dot(rayDir, rayDir)
    let d = simd_dot(axisDir, w0)
    let e = simd_dot(rayDir, w0)
    let denom = a * c - b * b
    if abs(denom) < 1e-5 { return nil }
    let t = (b * e - c * d) / denom
    return t
}

private func rayPlaneIntersect(rayOrigin: SIMD3<Float>,
                               rayDir: SIMD3<Float>,
                               planeOrigin: SIMD3<Float>,
                               planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
    let denom = simd_dot(rayDir, planeNormal)
    if abs(denom) < 1e-5 { return nil }
    let t = simd_dot(planeOrigin - rayOrigin, planeNormal) / denom
    if t < 0 { return nil }
    return rayOrigin + rayDir * t
}

/// 屏幕空间凸四边形点-在-多边形测试（按顺序遍历四条边的叉积同号即可）。
private func pointInQuad(px: Float, py: Float, quad: [(Float, Float)]) -> Bool {
    guard quad.count == 4 else { return false }
    var lastSign: Float = 0
    for i in 0..<4 {
        let (ax, ay) = quad[i]
        let (bx, by) = quad[(i + 1) % 4]
        let cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
        if cross != 0 {
            if lastSign == 0 {
                lastSign = cross
            } else if (lastSign > 0) != (cross > 0) {
                return false
            }
        }
    }
    return true
}

private func rotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float3x3 {
    let c = cosf(angle)
    let s = sinf(angle)
    let t = 1 - c
    let n = simd_normalize(axis)
    let x = n.x, y = n.y, z = n.z
    return simd_float3x3(
        SIMD3<Float>(t * x * x + c,     t * x * y + s * z, t * x * z - s * y),
        SIMD3<Float>(t * x * y - s * z, t * y * y + c,     t * y * z + s * x),
        SIMD3<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c)
    )
}

private func rotation4x4(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let r = rotationMatrix(angle: angle, axis: axis)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(r.columns.0, 0)
    m.columns.1 = SIMD4<Float>(r.columns.1, 0)
    m.columns.2 = SIMD4<Float>(r.columns.2, 0)
    return m
}

/// 沿世界轴 a 做非均匀缩放（factor）：S = I + (factor - 1) * a * aᵀ
private func scaleAlongAxisMatrix(factor: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = simd_normalize(axis)
    let k = factor - 1
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(1 + k * a.x * a.x, k * a.x * a.y,     k * a.x * a.z,     0)
    m.columns.1 = SIMD4<Float>(k * a.x * a.y,     1 + k * a.y * a.y, k * a.y * a.z,     0)
    m.columns.2 = SIMD4<Float>(k * a.x * a.z,     k * a.y * a.z,     1 + k * a.z * a.z, 0)
    return m
}
