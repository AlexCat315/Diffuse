import EditorCore
import EngineKernel
import CoveUI
import CoveUIRuntime
import Foundation
import RenderBackend
import SIMDCompat

enum MeshViewportInteraction {
    static func isLoopCutShortcut(_ key: KeyEvent,app: EditorApplication) -> Bool {
        app.meshEditing.isEditing && app.meshEditing.mode == .edge && key.scancode == 21
            && key.modifiers.hasCtrl && !key.modifiers.hasGui && !key.modifiers.hasAlt && !key.modifiers.hasShift
    }
    static func snapshot(app: EditorApplication, mode: EditorGizmoMode, space: EditorGizmoSpace) {
        let model = app.meshEditing
        guard !model.hasTopologyPreview, let id = model.entityID, let center = model.selectionCenter,
              let world = app.scene.entityWorldMatrix(id), let frame = EditorViewportDropTarget.frame,
              simd_determinant(world).isFinite, abs(simd_determinant(world)) > 1e-10,
              let gizmoMode = gizmoMode(mode) else { EditorGizmoController.shared.updateSnapshot(nil); return }
        let position = world*SIMD4(center,1)
        var pivot = world; pivot.columns.3 = position
        let camera = app.scene.currentRenderCamera()
        EditorGizmoController.shared.updateSnapshot(.init(mode: gizmoMode,space: space == .local ? .local : .world,
            camera: camera,frame: frame,entityID: id,entityWorldPosition: SIMD3(position.x,position.y,position.z),
            entityWorldMatrix: pivot,entityLocalMatrix: pivot,parentWorldMatrix: matrix_identity_float4x4,
            axisLength: EditorGizmoController.axisLength(camera: camera,position: SIMD3(position.x,position.y,position.z),viewportHeight: frame.height)))
    }

    static func handle(_ event: InputEvent, app: EditorApplication) -> Bool {
        let model = app.meshEditing
        model.synchronize()
        if case let .keyDown(key) = event,isLoopCutShortcut(key,app: app) {
            if !key.isRepeat { _ = model.beginLoopCut() }
            return true
        }
        if case let .keyDown(key) = event, EditorViewportKeyRoutingPolicy.handlesLocally(key), key.scancode == 43 {
            if key.isRepeat { return true }
            return model.setMode(model.isEditing ? .object : .vertex)
        }
        if case let .keyDown(key) = event, EditorViewportKeyRoutingPolicy.handlesLocally(key), (30...32).contains(key.scancode), model.canEnter {
            if key.isRepeat { return true }
            return model.setMode(key.scancode == 30 ? .vertex : key.scancode == 31 ? .edge : .face)
        }
        guard model.isEditing else { return false }
        let pointer = model.pointer
        switch event {
        case .windowFocusLost:
            _ = model.cancelInteractiveEdit(); pointer.clear(); return false
        case let .mouseButtonDown(button) where button.button == .left && !button.modifiers.hasAlt:
            if model.hasTopologyPreview { return true }
            guard let frame = EditorViewportDropTarget.frame, frame.contains(x: button.x,y: button.y) else { return false }
            _ = model.cancelTransform()
            app.scene.endInteractiveEditHistoryGroup()
            EditorViewportInputController.shared.endPointerSession()
            pointer.clear()
            pointer.start = SIMD2(button.x,button.y); pointer.current = pointer.start; pointer.modifiers = button.modifiers
            if !button.modifiers.hasShift, !button.modifiers.hasCtrl, !button.modifiers.hasGui,
               let drag = EditorGizmoController.shared.beginDrag(cursorX: button.x,cursorY: button.y) {
                if model.beginTransform(), let world = app.scene.entityWorldMatrix(drag.entityID) {
                    pointer.gizmoStart = drag.startEntityWorldMatrix; pointer.objectWorld = world
                } else { EditorGizmoController.shared.clearDrag() }
            }
            return true
        case let .mouseButtonDown(button) where button.button != .left || button.modifiers.hasAlt:
            _ = model.cancelTransform(); pointer.clear(); return false
        case .mouseWheel where pointer.start != nil: return true
        case let .mouseMotion(motion) where pointer.start != nil:
            pointer.current = SIMD2(motion.x,motion.y)
            if model.isTransforming, let start = pointer.gizmoStart, let world = pointer.objectWorld,
               let drag = EditorGizmoController.shared.activeDrag,
               let matrix = EditorGizmoController.shared.updateDrag(cursorX: motion.x,cursorY: motion.y) {
                let snapped = EditorTransformSnapping.apply(matrix,mode: drag.mode,state: app.store.state)
                _ = model.previewTransform(simd_inverse(world)*snapped*simd_inverse(start)*world)
            } else if app.store.gizmoMode == .boxSelect, let start = pointer.start,
                      simd_length_squared(SIMD2(motion.x,motion.y)-start) > 36 {
                pointer.marquee = UIRect(x: min(start.x,motion.x),y: min(start.y,motion.y),width: abs(start.x-motion.x),height: abs(start.y-motion.y))
                app.store.geometryChanged()
            }
            return true
        case let .mouseButtonUp(button) where button.button == .left && pointer.start != nil:
            defer { pointer.clear(); EditorGizmoController.shared.clearDrag(); app.store.geometryChanged() }
            if model.isTransforming { _ = model.finishTransform(); return true }
            guard let frame = EditorViewportDropTarget.frame,
                  let projection = EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: frame),
                  let picker = model.picker(), let start = pointer.start else { return true }
            let picked: Set<Int>
            if let rect = pointer.marquee { picked = picker.pick(in: rect,mode: model.mode,projection: projection,xray: model.xray) }
            else if simd_length_squared(SIMD2(button.x,button.y)-start) < 16 {
                picked = Set(picker.pick(x: button.x,y: button.y,mode: model.mode,projection: projection,xray: model.xray).map { [$0.index] } ?? [])
            } else { return true }
            let merged = EditorSelectionReducer.merge(base: Set(model.selection.map(UInt64.init)),picked: Set(picked.map(UInt64.init)),
                modifiers: pointer.modifiers,primaryModifierBehavior: app.store.state.selection.primarySelectBehavior)
            model.select(Set(merged.map(Int.init)))
            return true
        case let .keyDown(key) where EditorViewportKeyRoutingPolicy.handlesLocally(key):
            if key.scancode == 41 {
                if !model.cancelInteractiveEdit() { model.select([]) }
                pointer.clear(); PointerCaptureHolder.current?.release(); return true
            }
            if model.hasTopologyPreview {
                if key.scancode == 40, !key.isRepeat { _ = model.commitInteractiveEdit() }
                return true
            }
            if model.isTransforming { return true }
            switch key.scancode {
            case 4: if key.modifiers.hasAlt { model.select([]) } else { model.selectAll() }; return true
            case 8 where key.modifiers.hasShift && model.mode == .face: _ = model.extrudeRegion(); return true
            case 12 where model.mode == .face:
                if !key.isRepeat { _ = model.beginInset() }
                return true
            case 29 where key.modifiers.hasAlt: model.setXray(!model.xray); return true
            case 42,76:
                if key.isRepeat { return true }
                if key.modifiers.hasAlt { _ = model.dissolveSelection() }
                else { _ = model.deleteSelection() }
                return true
            default: return false
            }
        default: return false
        }
    }

    private static func gizmoMode(_ mode: EditorGizmoMode) -> EditorGizmoController.Mode? {
        switch mode { case .translate: .translate; case .rotate: .rotate; case .scale: .scale; default: nil }
    }
}
