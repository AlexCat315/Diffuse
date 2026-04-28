import EditorCore
import EngineKernel
import CoreGraphics
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime
import simd

struct ViewportPanel: View {
    let app: EditorApplication
    let scene: EditorSceneAdapter

    var body: some View {
        StoreScope(app.store) { store in
            let surface = app.currentViewportSurfaceState()
            let stats = app.currentRenderStats()
            let timing = app.currentFrameTiming()
            let entity = scene.entitySummary(id: store.state.selectedEntityID)
            let activeDrag = store.state.activeAssetDrag
            let gizmoMode = store.state.gizmoMode
            let gizmoSpace = store.state.gizmoSpace
            let shadingMode = store.state.viewportShadingMode

            // 推送 gizmo 控制器所需的快照（摄像机 / 视口矩形 / 实体世界坐标）。
            let _: Void = updateGizmoSnapshot(selectedID: store.state.selectedEntityID,
                                              gizmoMode: gizmoMode,
                                              gizmoSpace: gizmoSpace,
                                              surface: surface)

            ViewportHost(surface: surface,
                         onInputEvent: { event in
                             handleViewportInput(event)
                         },
                         onDrawableSizeChange: { app.setViewportDrawableSize($0) },
                         onScreenFrameChange: { frame in
                             EditorViewportDropTarget.frame = frame
                         },
                         onDrawOverlay: { list, frame in
                             drawGizmoOverlay(list: list,
                                              frame: frame,
                                              mode: gizmoMode,
                                              shadingMode: shadingMode,
                                              selectedID: store.state.selectedEntityID,
                                              selectedIDs: store.state.selectedEntityIDs)
                         }) {
                Box(direction: .column, alignItems: .stretch) {
                    Box(direction: .column, alignItems: .center, justifyContent: .center) {
                        if !surface.isValid {
                            ViewportIdleCard()
                        } else if let activeDrag {
                            DropTargetCard(label: activeDrag.displayName,
                                           kindLabel: activeDrag.kindLabel)
                        } else {
                            EmptyView()
                        }
                    }
                    .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)

                    ViewportChromeInputBlocker {
                        ViewportInfoBar(surface: surface,
                                        stats: stats,
                                        timing: timing,
                                        entity: entity,
                                        gizmoMode: gizmoMode,
                                        gizmoSpace: gizmoSpace,
                                        shadingMode: shadingMode,
                                        translateSnapEnabled: store.state.translateSnapEnabled,
                                        rotateSnapEnabled: store.state.rotateSnapEnabled,
                                        scaleSnapEnabled: store.state.scaleSnapEnabled,
                                        cmdSelectBehavior: store.state.cmdSelectBehavior,
                                        onSelectGizmoMode: { mode in
                                            if store.state.gizmoMode != mode {
                                                store.dispatch(.setGizmoMode(mode))
                                            }
                                        },
                                        onSelectGizmoSpace: { space in
                                            if store.state.gizmoSpace != space {
                                                store.dispatch(.setGizmoSpace(space))
                                            }
                                        },
                                        onSelectShadingMode: { mode in
                                            if store.state.viewportShadingMode != mode {
                                                store.dispatch(.setViewportShadingMode(mode))
                                            }
                                        },
                                        onToggleTranslateSnap: { enabled in
                                            store.dispatch(.setTranslateSnapEnabled(enabled))
                                        },
                                        onToggleRotateSnap: { enabled in
                                            store.dispatch(.setRotateSnapEnabled(enabled))
                                        },
                                        onToggleScaleSnap: { enabled in
                                            store.dispatch(.setScaleSnapEnabled(enabled))
                                        },
                                        onSetCommandSelectBehavior: { behavior in
                                            store.dispatch(.setCommandSelectBehavior(behavior))
                                        })
                    }
                        .absolutePosition(left: 10, top: 10)

                    ViewportChromeInputBlocker {
                        ViewCubeControl(scene: scene)
                    }
                    .absolutePosition(top: 10, right: 10)
                }
                .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
            }
            .flex()
            .background(.surfaceSunken)
        }
    }

    private func handleViewportInput(_ event: InputEvent) {
        let viewport = EditorViewportInputController.shared
        switch event {
        case let .mouseButtonDown(button) where button.button == .left:
            guard isInsideViewport(button.x, button.y) else {
                EditorGizmoController.shared.clearDrag()
                viewport.endPointerSession()
                return
            }
            viewport.modifiers = button.modifiers
            viewport.gizmoGroupTargets.removeAll(keepingCapacity: false)
            if button.modifiers.contains(.alt) {
                viewport.begin(.camera(.orbit, button: .left),
                               at: (button.x, button.y),
                               modifiers: button.modifiers)
                app.enqueueViewportInput(event)
                return
            }
            let mode = app.store.state.gizmoMode
            if (mode == .translate || mode == .rotate || mode == .scale),
               app.store.state.selectedEntityID != nil,
               let drag = EditorGizmoController.shared.beginDrag(
                   cursorX: button.x, cursorY: button.y)
            {
                viewport.gizmoGroupTargets = captureGizmoGroupTargets(primary: drag.entityID,
                                                                       selectedIDs: app.store.state.selectedEntityIDs)
                viewport.begin(.gizmo(button: .left),
                               at: (button.x, button.y),
                               modifiers: button.modifiers)
                app.enqueueViewportInput(event)
                return
            }
            viewport.begin(.pendingClick(button: .left),
                           at: (button.x, button.y),
                           modifiers: button.modifiers)
            app.enqueueViewportInput(event)
            return
        case let .mouseButtonDown(button) where button.button == .right:
            guard isInsideViewport(button.x, button.y) else {
                EditorGizmoController.shared.clearDrag()
                viewport.endPointerSession()
                return
            }
            let drag: EditorViewportInputController.CameraDrag = button.modifiers.contains(.alt) ? .dolly : .freelook
            viewport.begin(.camera(drag, button: .right),
                           at: (button.x, button.y),
                           modifiers: button.modifiers)
            app.enqueueViewportInput(event)
            return
        case let .mouseButtonDown(button) where button.button == .middle:
            guard isInsideViewport(button.x, button.y) else {
                EditorGizmoController.shared.clearDrag()
                viewport.endPointerSession()
                return
            }
            viewport.begin(.camera(.pan, button: .middle),
                           at: (button.x, button.y),
                           modifiers: button.modifiers)
            app.enqueueViewportInput(event)
            return
        case let .mouseMotion(motion):
            guard let interaction = viewport.activeInteraction else {
                return
            }
            switch interaction {
            case .gizmo:
                guard let drag = EditorGizmoController.shared.activeDrag,
                      let newMatrix = EditorGizmoController.shared.updateDrag(
                          cursorX: motion.x, cursorY: motion.y)
                else { return }
                let snapped = applyGizmoSnapping(newMatrix,
                                                 mode: drag.mode,
                                                 state: app.store.state)
                applyGizmoDragMatrix(snapped, drag: drag)
                app.enqueueViewportInput(event)
                return
            case .pendingClick:
                if viewport.boxSelectArmed,
                   app.store.state.activeAssetDrag == nil,
                   let down = viewport.leftDownAt
                {
                    let dx = motion.x - down.x
                    let dy = motion.y - down.y
                    if dx * dx + dy * dy > 64 {
                        viewport.activeInteraction = .marquee(button: .left)
                        viewport.marqueeStart = down
                        viewport.marqueeCurrent = (motion.x, motion.y)
                        app.enqueueViewportInput(event)
                        return
                    }
                }
                app.enqueueViewportInput(event)
                return
            case .marquee:
                viewport.marqueeCurrent = (motion.x, motion.y)
                app.enqueueViewportInput(event)
                return
            case .camera(let camDrag, _):
                let last = viewport.lastCursor ?? (motion.x, motion.y)
                let dx = motion.x - last.x
                let dy = motion.y - last.y
                viewport.lastCursor = (motion.x, motion.y)
                let frame = EditorViewportDropTarget.frame
                    ?? ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
                switch camDrag {
                case .orbit: scene.orbitCamera(deltaScreenX: dx, deltaScreenY: dy, in: frame)
                case .pan:   scene.panCamera(deltaScreenX: dx, deltaScreenY: dy, in: frame)
                case .dolly: scene.dollyCamera(deltaScreenY: dy)
                case .freelook:
                    scene.freelookCamera(deltaScreenX: dx,
                                         deltaScreenY: dy,
                                         pressedScancodes: viewport.pressedScancodes,
                                         modifiers: viewport.modifiers)
                }
                app.enqueueViewportInput(event)
                return
            }
        case let .mouseButtonUp(button) where button.button == .left:
            guard let interaction = viewport.activeInteraction else {
                return
            }
            switch interaction {
            case .camera(_, .left):
                viewport.endPointerSession()
                app.enqueueViewportInput(event)
                return
            case .gizmo(.left):
                EditorGizmoController.shared.clearDrag()
                viewport.endPointerSession()
                app.enqueueViewportInput(event)
                return
            case .marquee(.left):
                if let start = viewport.marqueeStart,
                   let current = viewport.marqueeCurrent,
                   let frame = EditorViewportDropTarget.frame
                {
                    let rect = normalizedRect(from: start, to: current)
                    let picked = scene.pickEntities(in: rect, frame: frame)
                    let baseSelection = app.store.state.selectedEntityIDs
                    let modifiers = viewport.modifiers.isEmpty ? app.inputState.modifiers : viewport.modifiers
                    let cmdBehavior = app.store.state.cmdSelectBehavior
                    let merged = mergeMarqueeSelection(base: baseSelection,
                                                       picked: picked,
                                                       modifiers: modifiers,
                                                       cmdBehavior: cmdBehavior)
                    app.store.dispatch(.setSelectedEntities(merged))
                }
                viewport.endPointerSession()
                app.enqueueViewportInput(event)
                return
            case .pendingClick(.left):
                if app.store.state.activeAssetDrag != nil {
                    _ = app.handleAssetDrop(at: button.x, cursorY: button.y)
                    viewport.endPointerSession()
                    app.enqueueViewportInput(event)
                    return
                }
                if let down = viewport.leftDownAt,
                   let frame = EditorViewportDropTarget.frame,
                   frame.contains(x: button.x, y: button.y)
                {
                    let dx = button.x - down.x
                    let dy = button.y - down.y
                    if dx * dx + dy * dy < 16 {
                        let picked = scene.pickEntity(cursorX: button.x,
                                                      cursorY: button.y,
                                                      in: frame)
                        let modifiers = viewport.modifiers.isEmpty ? app.inputState.modifiers : viewport.modifiers
                        let cmdBehavior = app.store.state.cmdSelectBehavior
                        let merged = mergeSinglePickSelection(base: app.store.state.selectedEntityIDs,
                                                              picked: picked,
                                                              modifiers: modifiers,
                                                              cmdBehavior: cmdBehavior)
                        app.store.dispatch(.setSelectedEntities(merged))
                    }
                }
                viewport.endPointerSession()
                app.enqueueViewportInput(event)
                return
            default:
                viewport.endPointerSession()
                app.enqueueViewportInput(event)
                return
            }
        case let .mouseButtonUp(button) where button.button == .right || button.button == .middle:
            if case .camera(_, let activeButton) = viewport.activeInteraction,
               activeButton == button.button {
                viewport.endPointerSession()
                app.enqueueViewportInput(event)
                return
            }
        case let .mouseWheel(wheel):
            if viewport.hasActivePointerSession { return }
            if let mx = wheel.mouseX, let my = wheel.mouseY,
               !isInsideViewport(mx, my) {
                return
            }
            // wheel.y > 0 表示向上滚（拉近）。每格缩放系数 ~0.9 / 1.1。
            let step = wheel.y
            if abs(step) > 0 {
                let factor = wheelZoomRatio(step)
                scene.zoomCamera(factor: factor)
                app.enqueueViewportInput(event)
                return
            }
        case let .keyDown(key):
            viewport.modifiers = key.modifiers
            viewport.pressedScancodes.insert(key.scancode)
            if isBoxSelectKey(key) {
                viewport.boxSelectArmed = true
                return
            }
            if viewport.activeCameraDrag == .freelook {
                scene.freelookCamera(deltaScreenX: 0,
                                     deltaScreenY: 0,
                                     pressedScancodes: viewport.pressedScancodes,
                                     modifiers: key.modifiers)
                return
            }
            if let mode = gizmoMode(for: key) {
                if app.store.state.gizmoMode != mode {
                    app.store.dispatch(.setGizmoMode(mode))
                }
                return
            }
            if handleEditingShortcut(key) { return }
            app.enqueueViewportInput(event)
            return
        case let .keyUp(key):
            viewport.modifiers = key.modifiers
            viewport.pressedScancodes.remove(key.scancode)
            if isBoxSelectKey(key) {
                viewport.boxSelectArmed = false
                viewport.marqueeStart = nil
                viewport.marqueeCurrent = nil
            }
            app.enqueueViewportInput(event)
            return
        default:
            break
        }
    }

    private func mergeMarqueeSelection(base: Set<UInt64>,
                                       picked: Set<UInt64>,
                                       modifiers: KeyModifiers,
                                       cmdBehavior: SelectionCommandBehavior) -> Set<UInt64> {
        if modifiers.contains(.shift) || modifiers.contains(.ctrl) || modifiers.contains(.gui) {
            var next = base
            for item in picked {
                if next.contains(item) {
                    next.remove(item)
                } else {
                    next.insert(item)
                }
            }
            return next
        }
        // No modifiers: replace selection
        return picked
    }

    private func mergeSinglePickSelection(base: Set<UInt64>,
                                          picked: UInt64?,
                                          modifiers: KeyModifiers,
                                          cmdBehavior: SelectionCommandBehavior) -> Set<UInt64> {
        let set = picked.map { Set([ $0 ]) } ?? []
        if picked == nil,
           modifiers.contains(.shift) || modifiers.contains(.ctrl) || modifiers.contains(.gui) {
            return base
        }
        return mergeMarqueeSelection(base: base, picked: set, modifiers: modifiers, cmdBehavior: cmdBehavior)
    }

    private func isInsideViewport(_ x: Float, _ y: Float) -> Bool {
        EditorViewportDropTarget.frame?.contains(x: x, y: y) == true
    }

    /// F = focus selection, Backspace/Delete = delete, Cmd/Ctrl+D = duplicate。
    private func handleEditingShortcut(_ key: KeyEvent) -> Bool {
        let selected = app.store.state.selectedEntityID
        switch key.keycode {
        case 0x66 /* f */:
            guard let id = selected else { return false }
            scene.frameEntity(id)
            return true
        case 0x08 /* backspace */, 0x7F /* delete */:
            guard let id = selected else { return false }
            if scene.deleteEntity(id) {
                app.store.dispatch(.setSelectedEntity(nil))
            }
            return true
        case 0x64 /* d */:
            let mods = key.modifiers
            let cmdLike = mods.contains(.lgui) || mods.contains(.rgui)
                       || mods.contains(.lctrl) || mods.contains(.rctrl)
            guard cmdLike, let id = selected else { return false }
            if let new = scene.duplicateEntity(id) {
                app.store.dispatch(.setSelectedEntity(new))
            }
            return true
        default:
            return false
        }
    }

    private func updateGizmoSnapshot(selectedID: UInt64?,
                                     gizmoMode: EditorGizmoMode,
                                     gizmoSpace: EditorGizmoSpace,
                                     surface: ViewportSurfaceState) {
        guard let mode = controllerMode(for: gizmoMode),
              let id = selectedID,
              let world = scene.entityWorldPosition(id),
              let worldMatrix = scene.entityWorldMatrix(id),
              let local = scene.entityLocalMatrix(id),
              let frame = EditorViewportDropTarget.frame,
              frame.width > 0, frame.height > 0
        else {
            EditorGizmoController.shared.updateSnapshot(nil)
            return
        }
        let camera = scene.currentRenderCamera()
        let dist = simd_length(world - camera.eye)
        // 距离自适应，与旧引擎 gizmo_pass.scaleForSelection 保持一致。
        let axisLength = max(0.7, min(3.4, dist * 0.2))
        let parentWorld = scene.entityParentWorldMatrix(id)
        EditorGizmoController.shared.updateSnapshot(
            EditorGizmoController.Snapshot(
                mode: mode,
                space: gizmoSpace == .local ? .local : .world,
                camera: camera,
                frame: frame,
                drawableWidth: Float(surface.width),
                drawableHeight: Float(surface.height),
                entityID: id,
                entityWorldPosition: world,
                entityWorldMatrix: worldMatrix,
                entityLocalMatrix: local,
                parentWorldMatrix: parentWorld,
                axisLength: axisLength
            )
        )
    }

    private func captureGizmoGroupTargets(primary: UInt64,
                                          selectedIDs: Set<UInt64>) -> [EditorViewportInputController.GizmoGroupTarget] {
        let rawSelection = selectedIDs.isEmpty ? Set([primary]) : selectedIDs
        var ordered = Array(rawSelection).sorted()
        if let index = ordered.firstIndex(of: primary) {
            ordered.remove(at: index)
        }
        ordered.insert(primary, at: 0)

        var targets: [EditorViewportInputController.GizmoGroupTarget] = []
        targets.reserveCapacity(ordered.count)
        for id in ordered {
            if id != primary, scene.entityHasAncestor(id, in: rawSelection) {
                continue
            }
            guard let world = scene.entityWorldMatrix(id) else { continue }
            let parentWorld = scene.entityParentWorldMatrix(id)
            targets.append(EditorViewportInputController.GizmoGroupTarget(
                entityID: id,
                startWorldMatrix: world,
                parentInverseMatrix: simd_inverse(parentWorld)
            ))
        }
        return targets
    }

    private func applyGizmoDragMatrix(_ primaryLocalMatrix: simd_float4x4,
                                      drag: EditorGizmoController.ActiveDrag) {
        let viewport = EditorViewportInputController.shared
        let targets = viewport.gizmoGroupTargets.isEmpty
            ? [EditorViewportInputController.GizmoGroupTarget(
                entityID: drag.entityID,
                startWorldMatrix: drag.startEntityWorldMatrix,
                parentInverseMatrix: drag.parentInverseMatrix
            )]
            : viewport.gizmoGroupTargets

        guard targets.count > 1 else {
            scene.setEntityLocalMatrix(drag.entityID, to: primaryLocalMatrix)
            return
        }

        let primaryNewWorld = drag.parentWorldMatrix * primaryLocalMatrix
        let deltaWorld = primaryNewWorld * simd_inverse(drag.startEntityWorldMatrix)
        for target in targets {
            if target.entityID == drag.entityID {
                scene.setEntityLocalMatrix(target.entityID, to: primaryLocalMatrix)
            } else {
                let nextWorld = deltaWorld * target.startWorldMatrix
                scene.setEntityLocalMatrix(target.entityID,
                                           to: target.parentInverseMatrix * nextWorld)
            }
        }
    }

    private func controllerMode(for mode: EditorGizmoMode) -> EditorGizmoController.Mode? {
        switch mode {
        case .translate: return .translate
        case .rotate: return .rotate
        case .scale: return .scale
        case .none: return nil
        }
    }

    private func drawGizmoOverlay(list: DrawList,
                                  frame: ViewportScreenFrame,
                                  mode: EditorGizmoMode,
                                  shadingMode: EditorViewportShadingMode,
                                  selectedID: UInt64?,
                                  selectedIDs: Set<UInt64>) {
        if shadingMode == .wireframe {
            drawWireframeOverlay(list: list, frame: frame, selectedID: selectedID)
        } else {
            drawSelectionHighlight(list: list, frame: frame, selectedIDs: selectedIDs)
        }
        drawMarqueeOverlay(list: list)

        guard let snap = EditorGizmoController.shared.snapshot,
              selectedID != nil,
              let projector = ScreenProjector(snap),
              let originScreen = projector.project(snap.entityWorldPosition)
        else { return }

        let activeAxis = EditorGizmoController.shared.activeDrag?.axis

        switch snap.mode {
        case .translate:
            drawAxisHandles(list: list, projector: projector, snap: snap,
                             originScreen: originScreen, activeAxis: activeAxis,
                             tipShape: .square)
        case .scale:
            drawAxisHandles(list: list, projector: projector, snap: snap,
                             originScreen: originScreen, activeAxis: activeAxis,
                             tipShape: .filledSquare)
        case .rotate:
            drawRotationCircles(list: list, projector: projector, snap: snap,
                                 activeAxis: activeAxis)
        }

        let centerSize: Float = snap.mode == .scale ? 14 : 16
        let centerColor: Color = switch snap.mode {
        case .translate: Color(r: 1.0, g: 0.92, b: 0.45, a: 0.92)
        case .rotate: Color(r: 1.0, g: 0.72, b: 0.32, a: 0.88)
        case .scale: Color(r: 0.95, g: 0.95, b: 0.98, a: 0.9)
        }
        list.addRect(UIRect(x: originScreen.x - centerSize * 0.5,
                            y: originScreen.y - centerSize * 0.5,
                            width: centerSize, height: centerSize),
                     color: centerColor)
        _ = frame
    }

    private enum AxisTipShape { case square, filledSquare }

    private func drawAxisHandles(list: DrawList,
                                 projector: ScreenProjector,
                                 snap: EditorGizmoController.Snapshot,
                                 originScreen: (x: Float, y: Float),
                                 activeAxis: EditorGizmoController.Axis?,
                                 tipShape: AxisTipShape) {
        for axis in EditorGizmoController.Axis.allCases {
            let tipWorld = snap.entityWorldPosition + snap.axisWorld(axis) * snap.axisLength
            guard let tip = projector.project(tipWorld) else { continue }
            let baseColor = axis.color
            let isActive = activeAxis == axis
            let color = Color(r: baseColor.x, g: baseColor.y, b: baseColor.z,
                              a: isActive ? 1.0 : 0.85)
            let thickness: Float = isActive ? 4 : 2
            list.addLine(fromX: originScreen.x, fromY: originScreen.y,
                         toX: tip.x, toY: tip.y,
                         thickness: thickness, color: color)
            let handleSize: Float = isActive ? 12 : 9
            switch tipShape {
            case .square, .filledSquare:
                list.addRect(UIRect(x: tip.x - handleSize * 0.5,
                                    y: tip.y - handleSize * 0.5,
                                    width: handleSize, height: handleSize),
                             color: color)
            }
        }
    }

    private func drawRotationCircles(list: DrawList,
                                     projector: ScreenProjector,
                                     snap: EditorGizmoController.Snapshot,
                                     activeAxis: EditorGizmoController.Axis?) {
        let radius = snap.axisLength
        let segments = 64
        for axis in EditorGizmoController.Axis.allCases {
            let (basisU, basisV) = snap.planeBasis(forRotateAxis: axis)
            let baseColor = axis.color
            let isActive = activeAxis == axis
            let color = Color(r: baseColor.x, g: baseColor.y, b: baseColor.z,
                              a: isActive ? 1.0 : 0.7)
            let thickness: Float = isActive ? 3 : 1.5
            var prev: (x: Float, y: Float)?
            for i in 0...segments {
                let t = Float(i) / Float(segments) * 2 * .pi
                let world = snap.entityWorldPosition
                            + (basisU * cosf(t) + basisV * sinf(t)) * radius
                guard let p = projector.project(world) else { prev = nil; continue }
                if let prevP = prev {
                    list.addLine(fromX: prevP.x, fromY: prevP.y,
                                 toX: p.x, toY: p.y,
                                 thickness: thickness, color: color)
                }
                prev = p
            }
        }
    }

    /// 三个 XY/YZ/ZX 平面手柄：在每个平面上画一个半透明矩形 + 描边。
    private func drawPlaneHandles(list: DrawList,
                                  projector: ScreenProjector,
                                  snap: EditorGizmoController.Snapshot) {
        let activePlane = EditorGizmoController.shared.activeDrag?.plane
        let lo = snap.axisLength * 0.15
        let hi = snap.axisLength * 0.45
        for plane in EditorGizmoController.Plane.allCases {
            let axes = snap.planeAxes(plane)
            let u = axes.basisU
            let v = axes.basisV
            let o = snap.entityWorldPosition
            let cornersWorld: [SIMD3<Float>] = [
                o + u * lo + v * lo,
                o + u * hi + v * lo,
                o + u * hi + v * hi,
                o + u * lo + v * hi
            ]
            var screenCorners: [(x: Float, y: Float)] = []
            screenCorners.reserveCapacity(4)
            var ok = true
            for c in cornersWorld {
                if let s = projector.project(c) {
                    screenCorners.append(s)
                } else { ok = false; break }
            }
            guard ok else { continue }

            let baseColor = plane.color
            let isActive = activePlane == plane
            let fillAlpha: Float = isActive ? 0.45 : 0.22
            let strokeAlpha: Float = isActive ? 1.0 : 0.7
            let fill = Color(r: baseColor.x, g: baseColor.y, b: baseColor.z, a: fillAlpha)
            let stroke = Color(r: baseColor.x, g: baseColor.y, b: baseColor.z, a: strokeAlpha)

            // 屏幕空间 AABB 近似填充（便宜的视觉提示，避免引入三角形 fill）。
            var minX = Float.infinity, minY = Float.infinity
            var maxX = -Float.infinity, maxY = -Float.infinity
            for s in screenCorners {
                minX = min(minX, s.x); minY = min(minY, s.y)
                maxX = max(maxX, s.x); maxY = max(maxY, s.y)
            }
            list.addRect(UIRect(x: minX, y: minY,
                                width: maxX - minX, height: maxY - minY),
                         color: fill)

            // 真实四边形描边。
            let thickness: Float = isActive ? 2.5 : 1.5
            for i in 0..<4 {
                let a = screenCorners[i]
                let b = screenCorners[(i + 1) % 4]
                list.addLine(fromX: a.x, fromY: a.y,
                             toX: b.x, toY: b.y,
                             thickness: thickness, color: stroke)
            }
        }
    }

    private func normalizedRect(from a: (x: Float, y: Float),
                                to b: (x: Float, y: Float)) -> UIRect {
        let x0 = min(a.x, b.x)
        let y0 = min(a.y, b.y)
        let x1 = max(a.x, b.x)
        let y1 = max(a.y, b.y)
        return UIRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func drawMarqueeOverlay(list: DrawList) {
        let viewport = EditorViewportInputController.shared
        guard let start = viewport.marqueeStart,
              let current = viewport.marqueeCurrent
        else { return }
        let rect = normalizedRect(from: start, to: current)
        let fill = Color(r: 0.36, g: 0.57, b: 0.95, a: 0.16)
        let stroke = Color(r: 0.62, g: 0.77, b: 1.0, a: 0.9)
        list.addRect(rect, color: fill)
        list.addLine(fromX: rect.x, fromY: rect.y,
                     toX: rect.x + rect.width, toY: rect.y,
                     thickness: 1.5, color: stroke)
        list.addLine(fromX: rect.x + rect.width, fromY: rect.y,
                     toX: rect.x + rect.width, toY: rect.y + rect.height,
                     thickness: 1.5, color: stroke)
        list.addLine(fromX: rect.x + rect.width, fromY: rect.y + rect.height,
                     toX: rect.x, toY: rect.y + rect.height,
                     thickness: 1.5, color: stroke)
        list.addLine(fromX: rect.x, fromY: rect.y + rect.height,
                     toX: rect.x, toY: rect.y,
                     thickness: 1.5, color: stroke)
    }

    private func drawGridOverlay(list: DrawList, frame: ViewportScreenFrame) {
        let lineColor = Color(r: 0.72, g: 0.74, b: 0.78, a: 0.14)
        let majorColor = Color(r: 0.82, g: 0.85, b: 0.9, a: 0.22)
        let halfExtent: Int = 20
        for i in -halfExtent...halfExtent {
            let x = Float(i)
            let isMajor = i % 5 == 0
            drawWorldLine(list: list,
                          frame: frame,
                          a: SIMD3<Float>(x, 0, Float(-halfExtent)),
                          b: SIMD3<Float>(x, 0, Float(halfExtent)),
                          color: isMajor ? majorColor : lineColor,
                          thickness: isMajor ? 1.3 : 1.0)
            let z = Float(i)
            drawWorldLine(list: list,
                          frame: frame,
                          a: SIMD3<Float>(Float(-halfExtent), 0, z),
                          b: SIMD3<Float>(Float(halfExtent), 0, z),
                          color: isMajor ? majorColor : lineColor,
                          thickness: isMajor ? 1.3 : 1.0)
        }
    }

    private func drawOriginAxesOverlay(list: DrawList, frame: ViewportScreenFrame) {
        drawWorldLine(list: list,
                      frame: frame,
                      a: SIMD3<Float>(-2, 0, 0),
                      b: SIMD3<Float>(2, 0, 0),
                      color: Color(r: 0.95, g: 0.3, b: 0.32, a: 0.9),
                      thickness: 2)
        drawWorldLine(list: list,
                      frame: frame,
                      a: SIMD3<Float>(0, -2, 0),
                      b: SIMD3<Float>(0, 2, 0),
                      color: Color(r: 0.37, g: 0.88, b: 0.44, a: 0.9),
                      thickness: 2)
        drawWorldLine(list: list,
                      frame: frame,
                      a: SIMD3<Float>(0, 0, -2),
                      b: SIMD3<Float>(0, 0, 2),
                      color: Color(r: 0.33, g: 0.57, b: 0.95, a: 0.9),
                      thickness: 2)
    }

    private func drawWireframeOverlay(list: DrawList,
                                      frame: ViewportScreenFrame,
                                      selectedID: UInt64?) {
        let selected = selectedID
        for line in scene.viewportWireframeLines() {
            let color: Color = line.entityID == selected
                ? Color(r: 1.0, g: 0.86, b: 0.46, a: 0.95)
                : Color(r: 0.86, g: 0.9, b: 0.95, a: 0.62)
            drawWorldLine(list: list,
                          frame: frame,
                          a: line.a,
                          b: line.b,
                          color: color,
                          thickness: line.entityID == selected ? 2 : 1)
        }
    }

    private func drawSelectionHighlight(list: DrawList,
                                        frame: ViewportScreenFrame,
                                        selectedIDs: Set<UInt64>) {
        guard !selectedIDs.isEmpty else { return }
        var drewMeshLines = false
        for line in scene.viewportWireframeLines(maxEdgesPerMesh: 768)
            where selectedIDs.contains(line.entityID) {
            drawWorldLine(list: list,
                          frame: frame,
                          a: line.a,
                          b: line.b,
                          color: Color(r: 1.0, g: 0.72, b: 0.18, a: 0.92),
                          thickness: 2.2)
            drewMeshLines = true
        }
        if drewMeshLines { return }

        for bounds in scene.viewportWorldBounds() where selectedIDs.contains(bounds.entityID) {
            drawAABBOverlay(list: list,
                            frame: frame,
                            min: bounds.min,
                            max: bounds.max,
                            color: Color(r: 1.0, g: 0.72, b: 0.18, a: 0.95),
                            thickness: 2)
        }
    }

    private func drawAABBOverlay(list: DrawList,
                                 frame: ViewportScreenFrame,
                                 min lo: SIMD3<Float>,
                                 max hi: SIMD3<Float>,
                                 color: Color,
                                 thickness: Float) {
        let corners = [
            SIMD3<Float>(lo.x, lo.y, lo.z),
            SIMD3<Float>(hi.x, lo.y, lo.z),
            SIMD3<Float>(hi.x, hi.y, lo.z),
            SIMD3<Float>(lo.x, hi.y, lo.z),
            SIMD3<Float>(lo.x, lo.y, hi.z),
            SIMD3<Float>(hi.x, lo.y, hi.z),
            SIMD3<Float>(hi.x, hi.y, hi.z),
            SIMD3<Float>(lo.x, hi.y, hi.z)
        ]
        let edges = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]
        for edge in edges {
            drawWorldLine(list: list,
                          frame: frame,
                          a: corners[edge.0],
                          b: corners[edge.1],
                          color: color,
                          thickness: thickness)
        }
    }

    private func drawWorldLine(list: DrawList,
                               frame: ViewportScreenFrame,
                               a: SIMD3<Float>,
                               b: SIMD3<Float>,
                               color: Color,
                               thickness: Float) {
        guard let pa = projectToViewport(a, frame: frame),
              let pb = projectToViewport(b, frame: frame)
        else { return }
        list.addLine(fromX: pa.x, fromY: pa.y,
                     toX: pb.x, toY: pb.y,
                     thickness: thickness,
                     color: color)
    }

    private func projectToViewport(_ world: SIMD3<Float>,
                                   frame: ViewportScreenFrame) -> (x: Float, y: Float)? {
        let camera = scene.currentRenderCamera()
        let forwardRaw = camera.target - camera.eye
        guard simd_length(forwardRaw) > 1e-5 else { return nil }
        let forward = simd_normalize(forwardRaw)
        let rightRaw = simd_cross(forward, camera.up)
        guard simd_length(rightRaw) > 1e-5 else { return nil }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))
        let view = lookAt(eye: camera.eye, target: camera.target, up: up)
        let proj = perspective(fovYRadians: camera.fovYRadians,
                               aspect: frame.width / max(frame.height, 1),
                               near: camera.near,
                               far: camera.far)
        let clip = proj * (view * SIMD4<Float>(world, 1))
        guard clip.w > 1e-4 else { return nil }
        let ndcX = clip.x / clip.w
        let ndcY = clip.y / clip.w
        let sx = frame.x + (ndcX * 0.5 + 0.5) * frame.width
        let sy = frame.y + (1 - (ndcY * 0.5 + 0.5)) * frame.height
        return (sx, sy)
    }

    private func applyGizmoSnapping(_ matrix: simd_float4x4,
                                    mode: EditorGizmoController.Mode,
                                    state: EditorState) -> simd_float4x4 {
        var result = matrix
        switch mode {
        case .translate:
            guard state.translateSnapEnabled else { return result }
            let step: Float = 0.5
            result.columns.3.x = quantize(result.columns.3.x, step: step)
            result.columns.3.y = quantize(result.columns.3.y, step: step)
            result.columns.3.z = quantize(result.columns.3.z, step: step)
            return result
        case .rotate:
            guard state.rotateSnapEnabled else { return result }
            let snapped = snapRotation(result, stepDegrees: 5)
            return snapped
        case .scale:
            guard state.scaleSnapEnabled else { return result }
            let snapped = snapScale(result, step: 0.05, minScale: 0.05)
            return snapped
        }
    }

    private func snapRotation(_ matrix: simd_float4x4,
                              stepDegrees: Float) -> simd_float4x4 {
        let decomp = decomposeTRS(matrix)
        let euler = quaternionToEulerXYZ(decomp.rotation)
        let step = stepDegrees * (.pi / 180)
        let snappedEuler = SIMD3<Float>(
            quantize(euler.x, step: step),
            quantize(euler.y, step: step),
            quantize(euler.z, step: step)
        )
        let snappedQ = eulerXYZToQuaternion(snappedEuler)
        return composeTRS(translation: decomp.translation,
                          rotation: snappedQ,
                          scale: decomp.scale)
    }

    private func snapScale(_ matrix: simd_float4x4,
                           step: Float,
                           minScale: Float) -> simd_float4x4 {
        let decomp = decomposeTRS(matrix)
        let snapped = SIMD3<Float>(
            max(minScale, quantize(decomp.scale.x, step: step)),
            max(minScale, quantize(decomp.scale.y, step: step)),
            max(minScale, quantize(decomp.scale.z, step: step))
        )
        return composeTRS(translation: decomp.translation,
                          rotation: decomp.rotation,
                          scale: snapped)
    }

    private func quantize(_ value: Float, step: Float) -> Float {
        guard step > 1e-6 else { return value }
        return (value / step).rounded() * step
    }

    private func decomposeTRS(_ matrix: simd_float4x4)
        -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        let t = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        let c0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let c1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let c2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let sx = max(simd_length(c0), 1e-8)
        let sy = max(simd_length(c1), 1e-8)
        let sz = max(simd_length(c2), 1e-8)
        let r0 = c0 / sx
        let r1 = c1 / sy
        let r2 = c2 / sz
        let rotM = simd_float3x3(columns: (r0, r1, r2))
        return (t, simd_quatf(rotM), SIMD3<Float>(sx, sy, sz))
    }

    private func composeTRS(translation t: SIMD3<Float>,
                            rotation r: simd_quatf,
                            scale s: SIMD3<Float>) -> simd_float4x4 {
        let rm = simd_float3x3(r)
        var out = matrix_identity_float4x4
        out.columns.0 = SIMD4<Float>(rm.columns.0 * s.x, 0)
        out.columns.1 = SIMD4<Float>(rm.columns.1 * s.y, 0)
        out.columns.2 = SIMD4<Float>(rm.columns.2 * s.z, 0)
        out.columns.3 = SIMD4<Float>(t, 1)
        return out
    }

    private func quaternionToEulerXYZ(_ q: simd_quatf) -> SIMD3<Float> {
        let x = q.imag.x
        let y = q.imag.y
        let z = q.imag.z
        let w = q.real

        let sinrCosp = 2 * (w * x + y * z)
        let cosrCosp = 1 - 2 * (x * x + y * y)
        let roll = atan2f(sinrCosp, cosrCosp)

        let sinp = 2 * (w * y - z * x)
        let pitch: Float
        if abs(sinp) >= 1 {
            pitch = copysignf(.pi * 0.5, sinp)
        } else {
            pitch = asinf(sinp)
        }

        let sinyCosp = 2 * (w * z + x * y)
        let cosyCosp = 1 - 2 * (y * y + z * z)
        let yaw = atan2f(sinyCosp, cosyCosp)

        return SIMD3<Float>(roll, pitch, yaw)
    }

    private func eulerXYZToQuaternion(_ euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return qz * qy * qx
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

    private func gizmoMode(for key: KeyEvent) -> EditorGizmoMode? {
        // 优先用 scancode（与键位物理位置绑定、与键盘布局无关），
        // 避免非 US 布局下 keycode 不匹配。SDL3 scancode：Q=20 W=26 E=8 R=21。
        switch key.scancode {
        case 20: return EditorGizmoMode.none   // Q
        case 26: return .translate              // W
        case 8:  return .rotate                 // E
        case 21: return .scale                  // R
        default: break
        }
        // Fallback：同时看 keycode。
        switch key.keycode {
        case 0x71: return EditorGizmoMode.none
        case 0x77: return .translate
        case 0x65: return .rotate
        case 0x72: return .scale
        default: return nil
        }
    }

    private func isBoxSelectKey(_ key: KeyEvent) -> Bool {
        key.scancode == 5 || key.keycode == 0x62
    }

    private func wheelZoomRatio(_ wheelDelta: Float) -> Float {
        let scaled = max(-4, min(4, wheelDelta * 1.2))
        return expf(-scaled * 0.16)
    }
}

private struct ViewportChromeInputBlocker<Content: View>: _PrimitiveView {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = false
        return node
    }

    func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setPointer(node, route: InputHandlerRoute(role: .control,
                                                           priority: .chrome,
                                                           debugName: "viewport.chrome")) { _, phase, eventPhase in
            guard eventPhase == .target else { return .ignored }
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
            case .up:
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
            }
            return .handled
        }
        registry.setMotion(node, route: InputHandlerRoute(role: .control,
                                                          priority: .chrome,
                                                          debugName: "viewport.chrome")) { _, phase in
            phase == .target ? .handled : .ignored
        }
        registry.setWheel(node, route: InputHandlerRoute(role: .control,
                                                         priority: .chrome,
                                                         debugName: "viewport.chrome")) { _, phase in
            phase == .target ? .handled : .ignored
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    var _children: [any View] {
        [content]
    }
}

private struct ViewCubeControl: _PrimitiveView {
    let scene: EditorSceneAdapter

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = false
        node.cursor = .pointer
        return node
    }

    func _updateNode(_ node: Node) {
        let scene = self.scene
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            Self.draw(list: list,
                      origin: (x: Float(origin.x), y: Float(origin.y)),
                      size: Float(min(node.frame.width, node.frame.height)),
                      camera: scene.currentRenderCamera())
        }

        guard let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setPointer(node, route: InputHandlerRoute(role: .control,
                                                           priority: .chrome,
                                                           debugName: "viewport.viewcube")) { event, phase, eventPhase in
            guard eventPhase == .target else { return .ignored }
            switch phase {
            case .down:
                node.attachments[Self.dragStartKey] = (event.x, event.y)
                node.attachments[Self.dragLastKey] = (event.x, event.y)
                node.attachments[Self.draggingKey] = false
                PointerCaptureHolder.current?.acquire(node)
                return .handled
            case .up:
                let wasDragging = node.attachments[Self.draggingKey] as? Bool ?? false
                if !wasDragging,
                   let axis = Self.hitAxis(eventX: event.x,
                                           eventY: event.y,
                                           node: node,
                                           camera: scene.currentRenderCamera()) {
                    scene.lookAlongAxis(axis)
                }
                node.attachments.removeValue(forKey: Self.dragStartKey)
                node.attachments.removeValue(forKey: Self.dragLastKey)
                node.attachments.removeValue(forKey: Self.draggingKey)
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                return .handled
            }
        }
        registry.setMotion(node, route: InputHandlerRoute(role: .control,
                                                          priority: .chrome,
                                                          debugName: "viewport.viewcube")) { event, phase in
            guard phase == .target,
                  PointerCaptureHolder.current?.target === node,
                  let start = node.attachments[Self.dragStartKey] as? (Float, Float),
                  let last = node.attachments[Self.dragLastKey] as? (Float, Float)
            else { return .ignored }
            let totalDX = event.x - start.0
            let totalDY = event.y - start.1
            if totalDX * totalDX + totalDY * totalDY > 9 {
                node.attachments[Self.draggingKey] = true
            }
            if node.attachments[Self.draggingKey] as? Bool == true {
                let dx = event.x - last.0
                let dy = event.y - last.1
                let frame = EditorViewportDropTarget.frame
                    ?? ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
                scene.orbitCamera(deltaScreenX: dx, deltaScreenY: dy, in: frame)
            }
            node.attachments[Self.dragLastKey] = (event.x, event.y)
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 92
        layout.height = 92
        return layout
    }

    private struct AxisEndpoint {
        var axis: SIMD3<Float>
        var screen: SIMD2<Float>
        var color: Color
        var depth: Float
    }

    private static let dragStartKey = "__viewport_viewcube_drag_start"
    private static let dragLastKey = "__viewport_viewcube_drag_last"
    private static let draggingKey = "__viewport_viewcube_dragging"

    private static func endpoints(camera: RenderCamera,
                                  origin: SIMD2<Float>,
                                  size: Float) -> [AxisEndpoint] {
        let center = origin + SIMD2<Float>(repeating: size * 0.5)
        let radius = size * 0.28
        let forward = simd_normalize(camera.target - camera.eye)
        var right = simd_cross(forward, camera.up)
        if simd_length(right) < 1e-5 {
            right = SIMD3<Float>(1, 0, 0)
        } else {
            right = simd_normalize(right)
        }
        let up = simd_normalize(simd_cross(right, forward))
        let axes: [(SIMD3<Float>, Color)] = [
            (SIMD3<Float>(1, 0, 0), Color(r: 0.95, g: 0.27, b: 0.34, a: 1)),
            (SIMD3<Float>(0, 1, 0), Color(r: 0.36, g: 0.86, b: 0.41, a: 1)),
            (SIMD3<Float>(0, 0, 1), Color(r: 0.34, g: 0.58, b: 0.95, a: 1))
        ]
        var out: [AxisEndpoint] = []
        out.reserveCapacity(6)
        for (axis, color) in axes {
            for sign in [Float(1), Float(-1)] {
                let dir = axis * sign
                let x = simd_dot(dir, right)
                let y = -simd_dot(dir, up)
                let z = simd_dot(dir, forward)
                let screen = center + SIMD2<Float>(x, y) * radius
                out.append(AxisEndpoint(axis: -dir,
                                        screen: screen,
                                        color: color,
                                        depth: z))
            }
        }
        return out.sorted { $0.depth < $1.depth }
    }

    private static func draw(list: DrawList,
                             origin: (x: Float, y: Float),
                             size: Float,
                             camera: RenderCamera) {
        let o = SIMD2<Float>(origin.x, origin.y)
        let rect = UIRect(x: origin.x, y: origin.y, width: size, height: size)
        list.addRoundedRect(rect,
                            radius: size * 0.5,
                            color: Color(r: 0.05, g: 0.06, b: 0.08, a: 0.58))
        let center = o + SIMD2<Float>(repeating: size * 0.5)
        for endpoint in endpoints(camera: camera, origin: o, size: size) {
            let alpha = max(0.32, min(1.0, 0.55 + endpoint.depth * 0.35))
            let c = endpoint.color.multipliedAlpha(alpha)
            let dotSize: Float = endpoint.depth >= 0 ? 12 : 8
            list.addLine(fromX: center.x,
                         fromY: center.y,
                         toX: endpoint.screen.x,
                         toY: endpoint.screen.y,
                         thickness: endpoint.depth >= 0 ? 2.2 : 1.3,
                         color: c)
            list.addRoundedRect(UIRect(x: endpoint.screen.x - dotSize * 0.5,
                                       y: endpoint.screen.y - dotSize * 0.5,
                                       width: dotSize,
                                       height: dotSize),
                                radius: dotSize * 0.5,
                                color: c)
        }
        list.addRoundedRect(UIRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5),
                            radius: 2.5,
                            color: Color(r: 0.92, g: 0.94, b: 0.98, a: 0.6))
    }

    private static func hitAxis(eventX: Float,
                                eventY: Float,
                                node: Node,
                                camera: RenderCamera) -> SIMD3<Float>? {
        let originPoint = absoluteOrigin(of: node)
        let origin = SIMD2<Float>(Float(originPoint.x), Float(originPoint.y))
        let size = Float(min(node.frame.width, node.frame.height))
        var best: (axis: SIMD3<Float>, d2: Float)?
        for endpoint in endpoints(camera: camera, origin: origin, size: size) {
            let dx = eventX - endpoint.screen.x
            let dy = eventY - endpoint.screen.y
            let d2 = dx * dx + dy * dy
            if d2 <= 144, d2 < (best?.d2 ?? .greatestFiniteMagnitude) {
                best = (endpoint.axis, d2)
            }
        }
        return best?.axis
    }

    private static func absoluteOrigin(of node: Node) -> CGPoint {
        var origin = node.frame.origin
        var current = node.parent
        while let parent = current {
            origin.x += parent.frame.origin.x
            origin.y += parent.frame.origin.y
            current = parent.parent
        }
        return origin
    }
}

private struct ViewportInfoBar: View {
    let surface: ViewportSurfaceState
    let stats: RenderFrameStats
    let timing: EditorFrameTiming
    let entity: EditorSceneEntitySummary?
    let gizmoMode: EditorGizmoMode
    let gizmoSpace: EditorGizmoSpace
    let shadingMode: EditorViewportShadingMode
    let translateSnapEnabled: Bool
    let rotateSnapEnabled: Bool
    let scaleSnapEnabled: Bool
    let cmdSelectBehavior: SelectionCommandBehavior
    let onSelectGizmoMode: (EditorGizmoMode) -> Void
    let onSelectGizmoSpace: (EditorGizmoSpace) -> Void
    let onSelectShadingMode: (EditorViewportShadingMode) -> Void
    let onToggleTranslateSnap: (Bool) -> Void
    let onToggleRotateSnap: (Bool) -> Void
    let onToggleScaleSnap: (Bool) -> Void
    let onSetCommandSelectBehavior: (SelectionCommandBehavior) -> Void

    var body: some View {
        let cpuMs = Float(stats.cpuFrameTotalNS) / 1_000_000
        let fps = Float(timing.framesPerSecond)
        let frameMs = Float(timing.frameMilliseconds)
        Box(direction: .column, alignItems: .flexStart, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Text(surface.isValid
                     ? "\(surface.width) × \(surface.height)"
                     : "Waiting for first render packet")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                if let entity {
                    Text(entity.name)
                        .font(.caption)
                        .foregroundColor(.onSurface)
                }

                Text(String(format: "FPS %.0f  %.2fms", fps, frameMs))
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)

                Text(String(format: "CPU %.2fms", cpuMs))
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            }

            Row(alignment: .center, spacing: 6) {
                IconButton(resource: ViewportToolbarIcon.cursor.resource,
                           size: 15,
                           tooltip: L("Pick")) {
                    onSelectGizmoMode(.none)
                }
                .toggleButtonStyle(gizmoMode == .none)
                IconButton(resource: ViewportToolbarIcon.translate.resource,
                           size: 15,
                           tooltip: L("Move")) {
                    onSelectGizmoMode(.translate)
                }
                .toggleButtonStyle(gizmoMode == .translate)
                IconButton(resource: ViewportToolbarIcon.rotate.resource,
                           size: 15,
                           tooltip: L("Rotate")) {
                    onSelectGizmoMode(.rotate)
                }
                .toggleButtonStyle(gizmoMode == .rotate)
                IconButton(resource: ViewportToolbarIcon.scale.resource,
                           size: 15,
                           tooltip: L("Scale")) {
                    onSelectGizmoMode(.scale)
                }
                .toggleButtonStyle(gizmoMode == .scale)

                ToggleChip(label: L("Local"), isActive: gizmoSpace == .local) {
                    onSelectGizmoSpace(.local)
                }
                ToggleChip(label: L("World"), isActive: gizmoSpace == .world) {
                    onSelectGizmoSpace(.world)
                }

                ToggleChip(label: L("T Snap"), isActive: translateSnapEnabled) {
                    onToggleTranslateSnap(!translateSnapEnabled)
                }
                ToggleChip(label: L("R Snap"), isActive: rotateSnapEnabled) {
                    onToggleRotateSnap(!rotateSnapEnabled)
                }
                ToggleChip(label: L("S Snap"), isActive: scaleSnapEnabled) {
                    onToggleScaleSnap(!scaleSnapEnabled)
                }

                ToggleChip(label: L("Cmd-Sub"), isActive: cmdSelectBehavior == .subtract) {
                    onSetCommandSelectBehavior(.subtract)
                }
                ToggleChip(label: L("Cmd-Tog"), isActive: cmdSelectBehavior == .toggle) {
                    onSetCommandSelectBehavior(.toggle)
                }

                IconButton(resource: ViewportToolbarIcon.lit.resource,
                           size: 15,
                           tooltip: L("Lit")) {
                    onSelectShadingMode(.lit)
                }
                .toggleButtonStyle(shadingMode == .lit)
                IconButton(resource: ViewportToolbarIcon.wireframe.resource,
                           size: 15,
                           tooltip: L("Wire")) {
                    onSelectShadingMode(.wireframe)
                }
                .toggleButtonStyle(shadingMode == .wireframe)

                Text("P \(stats.passCount)  D \(stats.drawCallCount)")
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            }
        }
        .padding(6)
        .background(.surfaceOverlay)
        .cornerRadius(2)
        .border(Color(r: 1, g: 1, b: 1, a: 0.08), width: 1)
    }
}

private struct ToggleChip: View {
    let label: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(label, lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(isActive ? .onAccent : .onSurface)
            }
            .frame(height: 26, minWidth: 44)
            .padding(horizontal: 6, vertical: 0)
            .background(isActive ? .accent : .surfaceSunken)
            .cornerRadius(4)
            .clipped()
        }
        .buttonStyle(.plain)
    }
}

private enum ViewportToolbarIcon: String {
    case cursor = "cursor-arrow-rays"
    case translate = "direction-arrows"
    case rotate = "toolbar-arrow-path"
    case scale = "arrows-pointing-out"
    case lit = "toolbar-eye"
    case wireframe = "grid-pattern"

    var resource: BundleImageResource {
        .svg(named: rawValue,
             in: .module,
             subdirectory: "ToolbarIcons")
    }
}

private struct ViewportIdleCard: View {
    var body: some View {
        Box(direction: .column, alignItems: .center, spacing: 4) {
            Text(L("Viewport idle"))
                .font(.headline)
                .foregroundColor(.onSurface)

            Text(L("Waiting for the first render packet from the engine."))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .background(.surfaceRaised)
        .cornerRadius(2)
        .border(Color(r: 1, g: 1, b: 1, a: 0.08), width: 1)
    }
}

private struct DropTargetCard: View {
    let label: String
    let kindLabel: String

    var body: some View {
        Box(direction: .column, alignItems: .center, spacing: 4) {
            Text(L("Drop to add"))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Text(label)
                .font(.headline)
                .foregroundColor(.onSurface)

            Text(kindLabel)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
        .background(.surfaceRaised)
        .cornerRadius(2)
        .border(Color(r: 0.54, g: 0.71, b: 0.98, a: 0.7), width: 2)
    }
}

private struct GizmoHUD: View {
    let entity: EditorSceneEntitySummary
    let mode: EditorGizmoMode

    var body: some View {
        Box(direction: .column, alignItems: .center, spacing: 6) {
            Text("Selected: \(entity.name)")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Row(alignment: .center, spacing: 8) {
                GizmoAxisChip(label: gizmoLabel(for: mode, axis: "X"),
                              color: Color(r: 0.95, g: 0.27, b: 0.34, a: 1))
                GizmoAxisChip(label: gizmoLabel(for: mode, axis: "Y"),
                              color: Color(r: 0.36, g: 0.86, b: 0.41, a: 1))
                GizmoAxisChip(label: gizmoLabel(for: mode, axis: "Z"),
                              color: Color(r: 0.34, g: 0.58, b: 0.95, a: 1))
            }

            Text("Mode: \(modeLabel(mode))  ·  Q/W/E/R to switch")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(.surfaceRaised)
        .cornerRadius(2)
        .border(Color(r: 1, g: 1, b: 1, a: 0.1), width: 1)
    }

    private func modeLabel(_ mode: EditorGizmoMode) -> String {
        switch mode {
        case .none: return "Pick"
        case .translate: return "Move"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        }
    }

    private func gizmoLabel(for mode: EditorGizmoMode, axis: String) -> String {
        switch mode {
        case .none: return axis
        case .translate: return "→\(axis)"
        case .rotate: return "↻\(axis)"
        case .scale: return "■\(axis)"
        }
    }
}

private struct GizmoAxisChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.mono)
            .foregroundColor(.onSurface)
            .padding(horizontal: 8, vertical: 3)
            .background(color)
            .cornerRadius(2)
    }
}
