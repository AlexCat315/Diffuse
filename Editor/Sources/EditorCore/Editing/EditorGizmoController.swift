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

    /// Gizmo 轴向空间：
    /// - `.local`：三轴随物体旋转（Maya/Blender/Unity 默认）。
    /// - `.world`：三轴始终对齐世界轴。
    public enum GizmoSpace: Sendable {
        case local
        case world
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
        public var space: GizmoSpace
        public var camera: RenderCamera
        public var frame: ViewportScreenFrame
        public var drawableWidth: Float
        public var drawableHeight: Float
        public var entityID: UInt64
        public var entityWorldPosition: SIMD3<Float>
        public var entityWorldMatrix: simd_float4x4
        public var entityLocalMatrix: simd_float4x4
        public var parentWorldMatrix: simd_float4x4
        public var axisLength: Float

        public init(mode: Mode,
                    space: GizmoSpace = .local,
                    camera: RenderCamera,
                    frame: ViewportScreenFrame,
                    drawableWidth: Float,
                    drawableHeight: Float,
                    entityID: UInt64,
                    entityWorldPosition: SIMD3<Float>,
                    entityWorldMatrix: simd_float4x4,
                    entityLocalMatrix: simd_float4x4,
                    parentWorldMatrix: simd_float4x4,
                    axisLength: Float) {
            self.mode = mode
            self.space = space
            self.camera = camera
            self.frame = frame
            self.drawableWidth = drawableWidth
            self.drawableHeight = drawableHeight
            self.entityID = entityID
            self.entityWorldPosition = entityWorldPosition
            self.entityWorldMatrix = entityWorldMatrix
            self.entityLocalMatrix = entityLocalMatrix
            self.parentWorldMatrix = parentWorldMatrix
            self.axisLength = axisLength
        }

        /// 当前 gizmo 轴在世界空间里的单位向量。`.local` 下从实体世界矩阵取列并归一化，
        /// `.world` 下返回原始世界轴。
        public func axisWorld(_ axis: Axis) -> SIMD3<Float> {
            switch space {
            case .world:
                return axis.worldDirection
            case .local:
                let column: SIMD4<Float>
                switch axis {
                case .x: column = entityWorldMatrix.columns.0
                case .y: column = entityWorldMatrix.columns.1
                case .z: column = entityWorldMatrix.columns.2
                }
                let v = SIMD3<Float>(column.x, column.y, column.z)
                let len = simd_length(v)
                return len > 1e-5 ? v / len : axis.worldDirection
            }
        }

        /// 为“以 axis 为法线”的平面（用于旋转环）提供两个世界空间正交基向量。
        public func planeBasis(forRotateAxis axis: Axis) -> (SIMD3<Float>, SIMD3<Float>) {
            let n = axisWorld(axis)
            let other: Axis = axis == .x ? .y : .x
            var u = axisWorld(other)
            u = u - n * simd_dot(u, n)
            if simd_length(u) < 1e-5 {
                let fallback: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                u = fallback - n * simd_dot(fallback, n)
            }
            u = simd_normalize(u)
            let v = simd_normalize(simd_cross(n, u))
            return (u, v)
        }

        /// 平面手柄的两轴 + 法线。
        public func planeAxes(_ plane: Plane) -> (basisU: SIMD3<Float>, basisV: SIMD3<Float>, normal: SIMD3<Float>) {
            switch plane {
            case .xy: return (axisWorld(.x), axisWorld(.y), axisWorld(.z))
            case .yz: return (axisWorld(.y), axisWorld(.z), axisWorld(.x))
            case .zx: return (axisWorld(.z), axisWorld(.x), axisWorld(.y))
            }
        }

        /// 摄像机 forward 向量（从 eye 指向 target，已归一化）。
        public var cameraForward: SIMD3<Float> {
            let raw = camera.target - camera.eye
            let len = simd_length(raw)
            return len > 1e-5 ? raw / len : SIMD3<Float>(0, 0, -1)
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
        // 拖拽时使用的“有效轴世界向量”（考虑 gizmoSpace）。
        public var axisWorld: SIMD3<Float>
        // 所有拖拽数学都基于“射线-平面相交”：
        // - translate axis: plane = 含 axis 并尽量面向摄像机（axis × (forward × axis)）。
        // - translate plane: plane normal = 平面手柄法线。
        // - rotate: plane normal = handle axis。
        // - scale axis: 同 translate axis。
        public var planeOrigin: SIMD3<Float>
        public var planeNormal: SIMD3<Float>
        public var startPlaneHit: SIMD3<Float>
        // rotate: 起始径向向量（在 plane 上，已归一化）
        public var startRadial: SIMD3<Float>
        // 拖拽时的 gizmo 远近 reference 长度（用于 scale 升压）
        public var referenceLength: Float
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

    /// 统一构造 ActiveDrag，把 parent / world 矩阵、起始世界矩阵、平面参数一次性算好，
    /// 便于后续 update 把世界变换换算回本地空间。
    private func makeDrag(snap: Snapshot,
                          axis: Axis,
                          plane: Plane?,
                          axisWorld: SIMD3<Float>,
                          planeOrigin: SIMD3<Float>,
                          planeNormal: SIMD3<Float>,
                          startPlaneHit: SIMD3<Float>,
                          startRadial: SIMD3<Float>) -> ActiveDrag {
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
            axisWorld: axisWorld,
            planeOrigin: planeOrigin,
            planeNormal: planeNormal,
            startPlaneHit: startPlaneHit,
            startRadial: startRadial,
            referenceLength: max(snap.axisLength, 0.001)
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
            let axisDir = snap.axisWorld(axis)
            let tip = snap.entityWorldPosition + axisDir * snap.axisLength
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

        let axisWorld = snap.axisWorld(axis)
        let planeNormal = axisDragPlaneNormal(axisWorld: axisWorld,
                                              cameraForward: snap.cameraForward,
                                              cameraUp: projector.cameraUp)
        guard let startHit = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: snap.entityWorldPosition,
            planeNormal: planeNormal
        ) else { return nil }

        let drag = makeDrag(snap: snap,
                            axis: axis,
                            plane: nil,
                            axisWorld: axisWorld,
                            planeOrigin: snap.entityWorldPosition,
                            planeNormal: planeNormal,
                            startPlaneHit: startHit,
                            startRadial: .zero)
        lock.lock(); _activeDrag = drag; lock.unlock()
        return drag
    }

    private func updateTranslateMatrix(snap: Snapshot,
                                       drag: ActiveDrag,
                                       ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard let curHit = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: drag.planeOrigin,
            planeNormal: drag.planeNormal
        ) else { return nil }
        // 在拖拽平面上的偏移投影到轴向，得到沏平移。
        let deltaWorld = curHit - drag.startPlaneHit
        let along = simd_dot(deltaWorld, drag.axisWorld)
        let newWorldPos = drag.startEntityWorldPosition + drag.axisWorld * along
        var worldMatrix = drag.startEntityWorldMatrix
        worldMatrix.columns.3 = SIMD4<Float>(newWorldPos, 1)
        return drag.parentInverseMatrix * worldMatrix
    }

    private func updateScaleMatrix(snap: Snapshot,
                                   drag: ActiveDrag,
                                   ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard let curHit = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: drag.planeOrigin,
            planeNormal: drag.planeNormal
        ) else { return nil }
        let along = simd_dot(curHit - drag.startPlaneHit, drag.axisWorld)
        let factor = max(0.05, 1 + along / drag.referenceLength)
        // 以 startEntityWorldPosition 为中心、沿世界轴做非均匀缩放：
        // 只缩放世界矩阵的三个基底列，保持平移不变，避免以世界原点为中心缩放。
        let s = scaleAlongAxisMatrix(factor: factor, axis: drag.axisWorld)
        let s3 = simd_float3x3(
            SIMD3<Float>(s.columns.0.x, s.columns.0.y, s.columns.0.z),
            SIMD3<Float>(s.columns.1.x, s.columns.1.y, s.columns.1.z),
            SIMD3<Float>(s.columns.2.x, s.columns.2.y, s.columns.2.z)
        )
        let m = drag.startEntityWorldMatrix
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let n0 = s3 * c0
        let n1 = s3 * c1
        let n2 = s3 * c2
        var worldMatrix = m
        worldMatrix.columns.0 = SIMD4<Float>(n0, 0)
        worldMatrix.columns.1 = SIMD4<Float>(n1, 0)
        worldMatrix.columns.2 = SIMD4<Float>(n2, 0)
        // worldMatrix.columns.3 保留原始平移。
        return drag.parentInverseMatrix * worldMatrix
    }

    // MARK: - Plane translate

    /// 平面手柄在世界空间的几何范围：以原点为起点沿 (basisU, basisV) 方向
    /// 各取 `axisLength * 0.15 .. axisLength * 0.45` 形成一个矩形。
    private func planeQuadCorners(snap: Snapshot, plane: Plane) -> [SIMD3<Float>] {
        let axes = snap.planeAxes(plane)
        let lo = snap.axisLength * 0.15
        let hi = snap.axisLength * 0.45
        let o = snap.entityWorldPosition
        return [
            o + axes.basisU * lo + axes.basisV * lo,
            o + axes.basisU * hi + axes.basisV * lo,
            o + axes.basisU * hi + axes.basisV * hi,
            o + axes.basisU * lo + axes.basisV * hi
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
            let axes = snap.planeAxes(plane)
            guard let hit = rayPlaneIntersect(
                rayOrigin: ray.origin,
                rayDir: ray.direction,
                planeOrigin: snap.entityWorldPosition,
                planeNormal: axes.normal
            ) else { return nil }

            let drag = makeDrag(snap: snap,
                                axis: .x,
                                plane: plane,
                                axisWorld: .zero,
                                planeOrigin: snap.entityWorldPosition,
                                planeNormal: axes.normal,
                                startPlaneHit: hit,
                                startRadial: .zero)
            lock.lock(); _activeDrag = drag; lock.unlock()
            return drag
        }
        return nil
    }

    private func updatePlaneTranslateMatrix(snap: Snapshot,
                                            drag: ActiveDrag,
                                            ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard drag.plane != nil else { return nil }
        guard let hit = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: drag.planeOrigin,
            planeNormal: drag.planeNormal
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
        struct Candidate { var axis: Axis; var screenDistance: Float }
        var best: Candidate?

        let radius = snap.axisLength
        let segments = 64

        for axis in Axis.allCases {
            let (basisU, basisV) = snap.planeBasis(forRotateAxis: axis)
            var prevScreen: (x: Float, y: Float)?
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
                        best = Candidate(axis: axis, screenDistance: d)
                    }
                }
                prevScreen = screen
            }
        }

        guard let candidate = best, candidate.screenDistance <= screenTolerance else {
            return nil
        }

        // 用真实 ray-平面求交得到更准的起始径向。
        guard let ray = projector.cursorRay(x: cursorX, y: cursorY) else { return nil }
        let axis = candidate.axis
        let axisWorld = snap.axisWorld(axis)
        let planeOrigin = snap.entityWorldPosition
        guard let hitWorld = rayPlaneIntersect(rayOrigin: ray.origin,
                                               rayDir: ray.direction,
                                               planeOrigin: planeOrigin,
                                               planeNormal: axisWorld) else { return nil }
        let radial = hitWorld - planeOrigin
        guard simd_length(radial) > 1e-4 else { return nil }
        let startRadial = simd_normalize(radial)

        let drag = makeDrag(snap: snap,
                            axis: axis,
                            plane: nil,
                            axisWorld: axisWorld,
                            planeOrigin: planeOrigin,
                            planeNormal: axisWorld,
                            startPlaneHit: hitWorld,
                            startRadial: startRadial)
        lock.lock(); _activeDrag = drag; lock.unlock()
        return drag
    }

    private func updateRotateMatrix(snap: Snapshot,
                                    drag: ActiveDrag,
                                    ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> simd_float4x4? {
        guard let hitWorld = rayPlaneIntersect(
            rayOrigin: ray.origin,
            rayDir: ray.direction,
            planeOrigin: drag.planeOrigin,
            planeNormal: drag.planeNormal
        ) else { return nil }

        let curRaw = hitWorld - drag.planeOrigin
        guard simd_length(curRaw) > 1e-4 else { return nil }
        let curRadial = simd_normalize(curRaw)
        let deltaAngle = signedAngleBetween(from: drag.startRadial,
                                            to: curRadial,
                                            axis: drag.axisWorld)
        // 以实体 startEntityWorldPosition 为轴心，只旋转世界矩阵的三个基底列，
        // 保持平移列不变，避免以世界原点为中心的轨道式旋转。
        let r3 = rotationMatrix(angle: deltaAngle, axis: drag.axisWorld)
        let m = drag.startEntityWorldMatrix
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let n0 = r3 * c0
        let n1 = r3 * c1
        let n2 = r3 * c2
        var worldMatrix = m
        worldMatrix.columns.0 = SIMD4<Float>(n0, 0)
        worldMatrix.columns.1 = SIMD4<Float>(n1, 0)
        worldMatrix.columns.2 = SIMD4<Float>(n2, 0)
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

/// 为一根世界轴选拖拽平面法线：平面含 axis、尽量面向摄像机，避免视线与轴近平行时的数值不稳。
private func axisDragPlaneNormal(axisWorld: SIMD3<Float>,
                                 cameraForward: SIMD3<Float>,
                                 cameraUp: SIMD3<Float>) -> SIMD3<Float> {
    let viewCrossAxis = simd_cross(cameraForward, axisWorld)
    var normal = simd_cross(axisWorld, viewCrossAxis)
    if simd_length(normal) < 1e-4 {
        normal = simd_cross(axisWorld, cameraUp)
    }
    if simd_length(normal) < 1e-4 {
        normal = simd_cross(axisWorld, SIMD3<Float>(1, 0, 0))
    }
    let len = simd_length(normal)
    return len > 1e-5 ? normal / len : cameraForward
}

/// 从 `from` 到 `to` 绕 `axis` 的有符号夹角，范围 [-π, π]。避免极角 atan2 的 ±π 跳变。
private func signedAngleBetween(from: SIMD3<Float>,
                                to: SIMD3<Float>,
                                axis: SIMD3<Float>) -> Float {
    let n = simd_length(axis) > 1e-5 ? simd_normalize(axis) : SIMD3<Float>(0, 1, 0)
    let cross = simd_cross(from, to)
    let sinAngle = simd_dot(n, cross)
    let cosAngle = max(-1, min(1, simd_dot(from, to)))
    return atan2f(sinAngle, cosAngle)
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
