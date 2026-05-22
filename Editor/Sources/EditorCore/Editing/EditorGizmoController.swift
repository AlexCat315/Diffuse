import Foundation
import GuavaUICompose
import RenderBackend
import SceneRuntime
import SIMDCompat

/// 瑙嗗彛鍐?3D 鎿嶇旱鍣紙gizmo锛夌殑鎷栧姩鐘舵€佷笌鍛戒腑娴嬭瘯锛岃鐩?
/// translate / rotate / scale 涓夌妯″紡銆?
///
/// ViewportPanel 姣忓抚璋冪敤 `updateSnapshot` 鍐欏叆鎽勫儚鏈恒€佸睆骞曠煩褰€?
/// 閫変腑瀹炰綋涓栫晫浣嶇疆涓庢湰鍦扮煩闃碉紱鎸囬拡/缁樺埗鍥炶皟閫氳繃
/// `EditorGizmoController.shared` 鍛戒腑娴嬭瘯骞朵骇鍑烘柊鐨?LocalTransform銆?
public final class EditorGizmoController: @unchecked Sendable {

    public static let shared = EditorGizmoController()

    public enum Mode: Sendable {
        case translate
        case rotate
        case scale
    }

    /// Gizmo 杞村悜绌洪棿锛?
    /// - `.local`锛氫笁杞撮殢鐗╀綋鏃嬭浆锛圡aya/Blender/Unity 榛樿锛夈€?
    /// - `.world`锛氫笁杞村缁堝榻愪笘鐣岃酱銆?
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

        /// 鍦ㄨ杞村搴旂殑鏃嬭浆骞抽潰锛堝嵆鍨傜洿浜庤杞寸殑骞抽潰锛夐噷鐨勪袱涓浜ゅ熀鍚戦噺锛?
        /// 鐢ㄦ潵鍦ㄤ笘鐣岀┖闂寸敾鍦?/ 璁＄畻瑙掑害銆?
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

        /// 骞抽潰閲岀殑涓や釜姝ｄ氦涓栫晫鍩哄悜閲忥紙U, V锛夈€?
        public var basis: (SIMD3<Float>, SIMD3<Float>) {
            switch self {
            case .xy: return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
            case .yz: return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
            case .zx: return (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0))
            }
        }

        /// 骞抽潰娉曞悜閲忥紙鎸囧悜鍙︿竴鏍逛笘鐣岃酱锛夈€?
        public var normal: SIMD3<Float> {
            switch self {
            case .xy: return SIMD3<Float>(0, 0, 1)
            case .yz: return SIMD3<Float>(1, 0, 0)
            case .zx: return SIMD3<Float>(0, 1, 0)
            }
        }

        /// 骞抽潰鎵嬫焺鐨勫～鍏呰壊锛氬彇鍙︿竴鏍逛笘鐣岃酱鐨勯鑹诧紝渚夸簬鍜岃酱绾垮尯鍒嗐€?
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

        /// 褰撳墠 gizmo 杞村湪涓栫晫绌洪棿閲岀殑鍗曚綅鍚戦噺銆俙.local` 涓嬩粠瀹炰綋涓栫晫鐭╅樀鍙栧垪骞跺綊涓€鍖栵紝
        /// `.world` 涓嬭繑鍥炲師濮嬩笘鐣岃酱銆?
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

        /// 涓衡€滀互 axis 涓烘硶绾库€濈殑骞抽潰锛堢敤浜庢棆杞幆锛夋彁渚涗袱涓笘鐣岀┖闂存浜ゅ熀鍚戦噺銆?
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

        /// 骞抽潰鎵嬫焺鐨勪袱杞?+ 娉曠嚎銆?
        public func planeAxes(_ plane: Plane) -> (basisU: SIMD3<Float>, basisV: SIMD3<Float>, normal: SIMD3<Float>) {
            switch plane {
            case .xy: return (axisWorld(.x), axisWorld(.y), axisWorld(.z))
            case .yz: return (axisWorld(.y), axisWorld(.z), axisWorld(.x))
            case .zx: return (axisWorld(.z), axisWorld(.x), axisWorld(.y))
            }
        }

        /// 鎽勫儚鏈?forward 鍚戦噺锛堜粠 eye 鎸囧悜 target锛屽凡褰掍竴鍖栵級銆?
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
        // 鎷栨嫿鏃朵娇鐢ㄧ殑鈥滄湁鏁堣酱涓栫晫鍚戦噺鈥濓紙鑰冭檻 gizmoSpace锛夈€?
        public var axisWorld: SIMD3<Float>
        // 鎵€鏈夋嫋鎷芥暟瀛﹂兘鍩轰簬鈥滃皠绾?骞抽潰鐩镐氦鈥濓細
        // - translate axis: plane = 鍚?axis 骞跺敖閲忛潰鍚戞憚鍍忔満锛坅xis 脳 (forward 脳 axis)锛夈€?
        // - translate plane: plane normal = 骞抽潰鎵嬫焺娉曠嚎銆?
        // - rotate: plane normal = handle axis銆?
        // - scale axis: 鍚?translate axis銆?
        public var planeOrigin: SIMD3<Float>
        public var planeNormal: SIMD3<Float>
        public var startPlaneHit: SIMD3<Float>
        // rotate: 璧峰寰勫悜鍚戦噺锛堝湪 plane 涓婏紝宸插綊涓€鍖栵級
        public var startRadial: SIMD3<Float>
        // free center handles use the camera-facing plane rather than a single axis.
        public var isFree: Bool
        public var uniformScaleStartDistance: Float
        // 鎷栨嫿鏃剁殑 gizmo 杩滆繎 reference 闀垮害锛堢敤浜?scale 鍗囧帇锛?
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

    /// 缁熶竴鏋勯€?ActiveDrag锛屾妸 parent / world 鐭╅樀銆佽捣濮嬩笘鐣岀煩闃点€佸钩闈㈠弬鏁颁竴娆℃€х畻濂斤紝
    /// 渚夸簬鍚庣画 update 鎶婁笘鐣屽彉鎹㈡崲绠楀洖鏈湴绌洪棿銆?
    private func makeDrag(snap: Snapshot,
                          axis: Axis,
                          plane: Plane?,
                          axisWorld: SIMD3<Float>,
                          planeOrigin: SIMD3<Float>,
                          planeNormal: SIMD3<Float>,
                          startPlaneHit: SIMD3<Float>,
                          startRadial: SIMD3<Float>,
                          isFree: Bool = false,
                          uniformScaleStartDistance: Float = 1) -> ActiveDrag {
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
            isFree: isFree,
            uniformScaleStartDistance: max(uniformScaleStartDistance, 0.05),
            referenceLength: max(snap.axisLength, 0.001)
        )
    }

    /// 鍛戒腑娴嬭瘯锛氬湪灞忓箷鍧愭爣 `(x, y)` 澶勫皾璇曞懡涓煇涓酱銆傚懡涓槇鍊?
    /// `screenTolerance` 鍗曚綅涓哄儚绱狅紙rotate 妯″紡涓嬪湪鍦嗗懆闄勮繎鐨勫宸級銆?
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
            if let drag = beginCenterDrag(snap: snap,
                                          projector: projector,
                                          cursorX: cursorX,
                                          cursorY: cursorY,
                                          screenTolerance: 20) {
                return drag
            }
            return beginAxisDrag(snap: snap,
                                 projector: projector,
                                 cursorX: cursorX, cursorY: cursorY,
                                 screenTolerance: max(screenTolerance, 18))
        case .scale:
            if let drag = beginCenterDrag(snap: snap,
                                          projector: projector,
                                          cursorX: cursorX,
                                          cursorY: cursorY,
                                          screenTolerance: 22) {
                return drag
            }
            return beginAxisDrag(snap: snap,
                                 projector: projector,
                                 cursorX: cursorX, cursorY: cursorY,
                                 screenTolerance: max(screenTolerance, 18))
        case .rotate:
            return beginRotateDrag(snap: snap,
                                   projector: projector,
                                   cursorX: cursorX, cursorY: cursorY,
                                   screenTolerance: max(screenTolerance, 18))
        }
    }

    /// 鎷栧姩涓細鏍规嵁褰撳墠鍏夋爣浣嶇疆杩斿洖鏂扮殑 LocalTransform 鐭╅樀銆?
    /// 杩斿洖 `nil` 琛ㄧず褰撳墠鍏夋爣涓嶅啀鍙В锛堜緥濡傝绾夸笌杞磋繎骞宠锛夈€?
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
        if drag.isFree {
            let deltaWorld = curHit - drag.startPlaneHit
            var worldMatrix = drag.startEntityWorldMatrix
            worldMatrix.columns.3 = SIMD4<Float>(drag.startEntityWorldPosition + deltaWorld, 1)
            return drag.parentInverseMatrix * worldMatrix
        }
        // 鍦ㄦ嫋鎷藉钩闈笂鐨勫亸绉绘姇褰卞埌杞村悜锛屽緱鍒版矎骞崇Щ銆?
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
        let factor: Float
        if drag.isFree {
            let currentOffset = curHit - drag.planeOrigin
            let currentDistance = simd_length(currentOffset)
            if currentDistance <= 1e-4 {
                factor = 0.05
            } else {
                let currentDirection = simd_normalize(currentOffset)
                let sameSide = simd_dot(currentDirection, drag.startRadial)
                factor = sameSide < -0.1
                    ? 0.05
                    : max(0.05, min(20, currentDistance / drag.uniformScaleStartDistance))
            }
        } else {
            let along = simd_dot(curHit - drag.startPlaneHit, drag.axisWorld)
            factor = max(0.05, 1 + along / drag.referenceLength)
        }
        // 浠?startEntityWorldPosition 涓轰腑蹇冦€佹部涓栫晫杞村仛闈炲潎鍖€缂╂斁锛?
        // 鍙缉鏀句笘鐣岀煩闃电殑涓変釜鍩哄簳鍒楋紝淇濇寔骞崇Щ涓嶅彉锛岄伩鍏嶄互涓栫晫鍘熺偣涓轰腑蹇冪缉鏀俱€?
        let m = drag.startEntityWorldMatrix
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let n0: SIMD3<Float>
        let n1: SIMD3<Float>
        let n2: SIMD3<Float>
        if drag.isFree {
            n0 = c0 * factor
            n1 = c1 * factor
            n2 = c2 * factor
        } else {
            let s = scaleAlongAxisMatrix(factor: factor, axis: drag.axisWorld)
            let s3 = simd_float3x3(columns: (
                SIMD3<Float>(s.columns.0.x, s.columns.0.y, s.columns.0.z),
                SIMD3<Float>(s.columns.1.x, s.columns.1.y, s.columns.1.z),
                SIMD3<Float>(s.columns.2.x, s.columns.2.y, s.columns.2.z)
            ))
            n0 = s3 * c0
            n1 = s3 * c1
            n2 = s3 * c2
        }
        var worldMatrix = m
        worldMatrix.columns.0 = SIMD4<Float>(n0, 0)
        worldMatrix.columns.1 = SIMD4<Float>(n1, 0)
        worldMatrix.columns.2 = SIMD4<Float>(n2, 0)
        // worldMatrix.columns.3 淇濈暀鍘熷骞崇Щ銆?
        return drag.parentInverseMatrix * worldMatrix
    }

    // MARK: - Plane translate

    private func beginCenterDrag(snap: Snapshot,
                                 projector: ScreenProjector,
                                 cursorX: Float,
                                 cursorY: Float,
                                 screenTolerance: Float) -> ActiveDrag? {
        guard let originScreen = projector.project(snap.entityWorldPosition) else { return nil }
        let dx = cursorX - originScreen.x
        let dy = cursorY - originScreen.y
        guard (dx * dx + dy * dy).squareRoot() <= screenTolerance else { return nil }
        guard let ray = projector.cursorRay(x: cursorX, y: cursorY) else { return nil }
        guard let hit = rayPlaneIntersect(rayOrigin: ray.origin,
                                          rayDir: ray.direction,
                                          planeOrigin: snap.entityWorldPosition,
                                          planeNormal: snap.cameraForward) else { return nil }

        let offset = hit - snap.entityWorldPosition
        let offsetLength = simd_length(offset)
        let startRadial = offsetLength > 1e-4 ? offset / offsetLength : projector.cameraRight
        let dragAxis = simd_normalize(projector.cameraRight + projector.cameraUp)
        let drag = makeDrag(snap: snap,
                            axis: .x,
                            plane: nil,
                            axisWorld: dragAxis,
                            planeOrigin: snap.entityWorldPosition,
                            planeNormal: snap.cameraForward,
                            startPlaneHit: hit,
                            startRadial: startRadial,
                            isFree: true,
                            uniformScaleStartDistance: max(offsetLength, snap.axisLength * 0.18))
        lock.lock(); _activeDrag = drag; lock.unlock()
        return drag
    }

    /// 骞抽潰鎵嬫焺鍦ㄤ笘鐣岀┖闂寸殑鍑犱綍鑼冨洿锛氫互鍘熺偣涓鸿捣鐐规部 (basisU, basisV) 鏂瑰悜
    /// 鍚勫彇 `axisLength * 0.15 .. axisLength * 0.45` 褰㈡垚涓€涓煩褰€?
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
            // 涓栫晫绌洪棿鍥涚偣鎶曞埌灞忓箷锛屽仛鍑稿洓杈瑰舰鐐?鍦?澶氳竟褰㈡祴璇曘€?
            var screenCorners: [(Float, Float)] = []
            screenCorners.reserveCapacity(4)
            for c in corners {
                guard let s = projector.project(c) else { screenCorners.removeAll(); break }
                screenCorners.append((s.x, s.y))
            }
            guard screenCorners.count == 4 else { continue }
            guard pointInQuad(px: cursorX, py: cursorY, quad: screenCorners) else { continue }

            // 鍛戒腑锛氱敤 ray-plane 姹備氦寰楀埌璧峰涓栫晫鐐广€?
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
        // 鍦ㄤ笁涓棆杞渾閲屾寫鍛戒腑鐨勶細姣忎釜鍦嗛噰鏍?N 涓偣锛屽厛鍦ㄥ睆骞曚笂鎵炬渶杩戠偣璺濈銆?
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

        // 鐢ㄧ湡瀹?ray-骞抽潰姹備氦寰楀埌鏇村噯鐨勮捣濮嬪緞鍚戙€?
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
        // 浠ュ疄浣?startEntityWorldPosition 涓鸿酱蹇冿紝鍙棆杞笘鐣岀煩闃电殑涓変釜鍩哄簳鍒楋紝
        // 淇濇寔骞崇Щ鍒椾笉鍙橈紝閬垮厤浠ヤ笘鐣屽師鐐逛负涓績鐨勮建閬撳紡鏃嬭浆銆?
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
        let cam = snapshot.camera
        guard let projection = EditorViewportProjection(camera: cam, frame: frame) else { return nil }
        self.frame = frame
        self.cameraEye = cam.eye
        self.viewMatrix = projection.viewMatrix
        self.projMatrix = projection.projectionMatrix
        self.cameraForward = projection.cameraForward
        self.cameraRight = projection.cameraRight
        self.cameraUp = projection.cameraUp
        self.aspect = projection.aspect
        self.tanHalfFov = projection.tanHalfFov
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

/// 涓轰竴鏍逛笘鐣岃酱閫夋嫋鎷藉钩闈㈡硶绾匡細骞抽潰鍚?axis銆佸敖閲忛潰鍚戞憚鍍忔満锛岄伩鍏嶈绾夸笌杞磋繎骞宠鏃剁殑鏁板€间笉绋炽€?
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

/// 浠?`from` 鍒?`to` 缁?`axis` 鐨勬湁绗﹀彿澶硅锛岃寖鍥?[-蟺, 蟺]銆傞伩鍏嶆瀬瑙?atan2 鐨?卤蟺 璺冲彉銆?
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

/// 灞忓箷绌洪棿鍑稿洓杈瑰舰鐐?鍦?澶氳竟褰㈡祴璇曪紙鎸夐『搴忛亶鍘嗗洓鏉¤竟鐨勫弶绉悓鍙峰嵆鍙級銆?
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
    return simd_float3x3(columns: (
        SIMD3<Float>(t * x * x + c,     t * x * y + s * z, t * x * z - s * y),
        SIMD3<Float>(t * x * y - s * z, t * y * y + c,     t * y * z + s * x),
        SIMD3<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c)
    ))
}

private func rotation4x4(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let r = rotationMatrix(angle: angle, axis: axis)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(r.columns.0, 0)
    m.columns.1 = SIMD4<Float>(r.columns.1, 0)
    m.columns.2 = SIMD4<Float>(r.columns.2, 0)
    return m
}

/// 娌夸笘鐣岃酱 a 鍋氶潪鍧囧寑缂╂斁锛坒actor锛夛細S = I + (factor - 1) * a * a岬€
private func scaleAlongAxisMatrix(factor: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = simd_normalize(axis)
    let k = factor - 1
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(1 + k * a.x * a.x, k * a.x * a.y,     k * a.x * a.z,     0)
    m.columns.1 = SIMD4<Float>(k * a.x * a.y,     1 + k * a.y * a.y, k * a.y * a.z,     0)
    m.columns.2 = SIMD4<Float>(k * a.x * a.z,     k * a.y * a.z,     1 + k * a.z * a.z, 0)
    return m
}
