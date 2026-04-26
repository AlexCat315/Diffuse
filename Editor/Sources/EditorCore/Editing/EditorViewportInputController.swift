import EngineKernel
import Foundation
import simd

/// 视口相机拖拽 / 选择状态的全局持有者。
/// `ViewportPanel.handleViewportInput` 是值类型 view body 里的临时方法，
/// 没法持有状态；这里用单例承接跨事件的轻量上下文。
public final class EditorViewportInputController: @unchecked Sendable {
    public static let shared = EditorViewportInputController()
    private init() {}

    public enum CameraDrag: Equatable { case orbit, pan, dolly, freelook }

    public enum ActiveInteraction: Equatable {
        case pendingClick(button: MouseButton)
        case camera(CameraDrag, button: MouseButton)
        case gizmo(button: MouseButton)
        case marquee(button: MouseButton)
    }

    public struct GizmoGroupTarget: Sendable {
        public var entityID: UInt64
        public var startWorldMatrix: simd_float4x4
        public var parentInverseMatrix: simd_float4x4

        public init(entityID: UInt64,
                    startWorldMatrix: simd_float4x4,
                    parentInverseMatrix: simd_float4x4) {
            self.entityID = entityID
            self.startWorldMatrix = startWorldMatrix
            self.parentInverseMatrix = parentInverseMatrix
        }
    }

    public var activeCameraDrag: CameraDrag?
    public var activeInteraction: ActiveInteraction?
    public var lastCursor: (x: Float, y: Float)?

    /// 鼠标按下时记录起点，以便释放时判断是否算 "click" 触发拾取。
    public var leftDownAt: (x: Float, y: Float)?
    public var marqueeStart: (x: Float, y: Float)?
    public var marqueeCurrent: (x: Float, y: Float)?
    public var modifiers: KeyModifiers = []
    public var pressedScancodes: Set<UInt32> = []
    public var boxSelectArmed: Bool = false
    public var gizmoGroupTargets: [GizmoGroupTarget] = []

    public var hasActivePointerSession: Bool {
        activeInteraction != nil
    }

    public func begin(_ interaction: ActiveInteraction,
                      at point: (x: Float, y: Float),
                      modifiers: KeyModifiers) {
        self.activeInteraction = interaction
        self.modifiers = modifiers
        self.lastCursor = point
        self.leftDownAt = point
        self.marqueeStart = nil
        self.marqueeCurrent = nil
        switch interaction {
        case .camera(let drag, _):
            self.activeCameraDrag = drag
        default:
            self.activeCameraDrag = nil
        }
    }

    public func endPointerSession(keepingKeyboardState: Bool = true) {
        activeInteraction = nil
        activeCameraDrag = nil
        lastCursor = nil
        leftDownAt = nil
        marqueeStart = nil
        marqueeCurrent = nil
        gizmoGroupTargets.removeAll(keepingCapacity: false)
        if !keepingKeyboardState {
            modifiers = []
            pressedScancodes.removeAll(keepingCapacity: false)
            boxSelectArmed = false
        }
    }

    public func reset() {
        endPointerSession(keepingKeyboardState: false)
        activeInteraction = nil
        modifiers = []
        pressedScancodes.removeAll(keepingCapacity: false)
        boxSelectArmed = false
        gizmoGroupTargets.removeAll(keepingCapacity: false)
    }
}
