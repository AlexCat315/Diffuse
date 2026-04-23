import EditorCore
import EngineKernel
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
                                              selectedID: store.state.selectedEntityID)
                         }) {
                Box(direction: .column, alignItems: .stretch) {
                    ViewportInfoBar(surface: surface,
                                    stats: stats,
                                    entity: entity,
                                    gizmoMode: gizmoMode,
                                    gizmoSpace: gizmoSpace,
                                    shadingMode: shadingMode,
                                    translateSnapEnabled: store.state.translateSnapEnabled,
                                    rotateSnapEnabled: store.state.rotateSnapEnabled,
                                    scaleSnapEnabled: store.state.scaleSnapEnabled,
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
                                    })

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
                    .flex()
                }
                .padding(10)
            }
            .flex()
            .background(.surfaceSunken)
        }
    }

    private func handleViewportInput(_ event: InputEvent) {
        let viewport = EditorViewportInputController.shared
        switch event {
        case let .mouseButtonDown(button) where button.button == .left:
            viewport.leftDownAt = (button.x, button.y)
            viewport.marqueeStart = nil
            viewport.marqueeCurrent = nil
            let mode = app.store.state.gizmoMode
            if (mode == .translate || mode == .rotate || mode == .scale),
               app.store.state.selectedEntityID != nil,
               EditorGizmoController.shared.beginDrag(
                   cursorX: button.x, cursorY: button.y) != nil
            {
                return
            }
        case let .mouseButtonDown(button) where button.button == .right:
            viewport.activeCameraDrag = .orbit
            viewport.lastCursor = (button.x, button.y)
            return
        case let .mouseButtonDown(button) where button.button == .middle:
            viewport.activeCameraDrag = .pan
            viewport.lastCursor = (button.x, button.y)
            return
        case let .mouseMotion(motion):
            if let drag = EditorGizmoController.shared.activeDrag,
               let newMatrix = EditorGizmoController.shared.updateDrag(
                   cursorX: motion.x, cursorY: motion.y)
            {
                let snapped = applyGizmoSnapping(newMatrix,
                                                 mode: drag.mode,
                                                 state: app.store.state)
                scene.setEntityLocalMatrix(drag.entityID, to: snapped)
                return
            }
            if viewport.leftDownAt != nil,
               viewport.activeCameraDrag == nil,
               app.store.state.gizmoMode == .none,
               app.store.state.activeAssetDrag == nil,
               let down = viewport.leftDownAt,
               let frame = EditorViewportDropTarget.frame,
               frame.contains(x: motion.x, y: motion.y)
            {
                let dx = motion.x - down.x
                let dy = motion.y - down.y
                if dx * dx + dy * dy >= 16 {
                    viewport.marqueeStart = down
                    viewport.marqueeCurrent = (motion.x, motion.y)
                    return
                }
            }
            if viewport.marqueeStart != nil {
                viewport.marqueeCurrent = (motion.x, motion.y)
                return
            }
            if let camDrag = viewport.activeCameraDrag,
               let frame = EditorViewportDropTarget.frame
            {
                let last = viewport.lastCursor ?? (motion.x, motion.y)
                let dx = motion.x - last.x
                let dy = motion.y - last.y
                viewport.lastCursor = (motion.x, motion.y)
                switch camDrag {
                case .orbit: scene.orbitCamera(deltaScreenX: dx, deltaScreenY: dy, in: frame)
                case .pan:   scene.panCamera(deltaScreenX: dx, deltaScreenY: dy, in: frame)
                }
                return
            }
        case let .mouseButtonUp(button) where button.button == .left:
            if EditorGizmoController.shared.activeDrag != nil {
                EditorGizmoController.shared.clearDrag()
                viewport.leftDownAt = nil
                viewport.marqueeStart = nil
                viewport.marqueeCurrent = nil
                return
            }
            if app.store.state.activeAssetDrag != nil {
                _ = app.handleAssetDrop(at: button.x, cursorY: button.y)
                viewport.leftDownAt = nil
                viewport.marqueeStart = nil
                viewport.marqueeCurrent = nil
                return
            }
            if let start = viewport.marqueeStart,
               let current = viewport.marqueeCurrent,
               let frame = EditorViewportDropTarget.frame
            {
                let rect = normalizedRect(from: start, to: current)
                let selected = scene.pickEntities(in: rect, frame: frame)
                app.store.dispatch(.setSelectedEntities(selected))
                viewport.leftDownAt = nil
                viewport.marqueeStart = nil
                viewport.marqueeCurrent = nil
                return
            }
            // 没拖 gizmo / 没拖资产 → 视为单击拾取。
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
                    app.store.dispatch(.setSelectedEntity(picked))
                }
            }
            viewport.leftDownAt = nil
            viewport.marqueeStart = nil
            viewport.marqueeCurrent = nil
        case let .mouseButtonUp(button) where button.button == .right || button.button == .middle:
            if viewport.activeCameraDrag != nil {
                viewport.activeCameraDrag = nil
                viewport.lastCursor = nil
                return
            }
        case let .mouseWheel(wheel):
            // wheel.y > 0 表示向上滚（拉近）。每格缩放系数 ~0.9 / 1.1。
            let step = wheel.y
            if abs(step) > 0 {
                let factor = powf(0.9, step)
                scene.zoomCamera(factor: factor)
                return
            }
        case let .keyDown(key):
            if let mode = gizmoMode(for: key) {
                if app.store.state.gizmoMode != mode {
                    app.store.dispatch(.setGizmoMode(mode))
                }
                return
            }
            if handleEditingShortcut(key) { return }
        default:
            break
        }
        app.enqueueViewportInput(event)
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
                                  selectedID: UInt64?) {
        drawGridOverlay(list: list, frame: frame)
        drawOriginAxesOverlay(list: list, frame: frame)
        if shadingMode == .wireframe {
            drawWireframeOverlay(list: list, frame: frame, selectedID: selectedID)
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
            drawPlaneHandles(list: list, projector: projector, snap: snap)
        case .scale:
            drawAxisHandles(list: list, projector: projector, snap: snap,
                             originScreen: originScreen, activeAxis: activeAxis,
                             tipShape: .filledSquare)
        case .rotate:
            drawRotationCircles(list: list, projector: projector, snap: snap,
                                 activeAxis: activeAxis)
        }

        let centerSize: Float = 4
        list.addRect(UIRect(x: originScreen.x - centerSize * 0.5,
                            y: originScreen.y - centerSize * 0.5,
                            width: centerSize, height: centerSize),
                     color: Color(r: 0.95, g: 0.95, b: 0.95, a: 0.95))
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
        for bound in scene.viewportWorldBounds() {
            let color: Color = bound.entityID == selected
                ? Color(r: 1.0, g: 0.86, b: 0.46, a: 0.95)
                : Color(r: 0.86, g: 0.9, b: 0.95, a: 0.62)
            drawWorldAABBEdges(list: list,
                               frame: frame,
                               min: bound.min,
                               max: bound.max,
                               color: color,
                               thickness: bound.entityID == selected ? 2 : 1)
        }
    }

    private func drawWorldAABBEdges(list: DrawList,
                                    frame: ViewportScreenFrame,
                                    min lo: SIMD3<Float>,
                                    max hi: SIMD3<Float>,
                                    color: Color,
                                    thickness: Float) {
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(lo.x, lo.y, lo.z),
            SIMD3<Float>(hi.x, lo.y, lo.z),
            SIMD3<Float>(hi.x, hi.y, lo.z),
            SIMD3<Float>(lo.x, hi.y, lo.z),
            SIMD3<Float>(lo.x, lo.y, hi.z),
            SIMD3<Float>(hi.x, lo.y, hi.z),
            SIMD3<Float>(hi.x, hi.y, hi.z),
            SIMD3<Float>(lo.x, hi.y, hi.z)
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]
        for (a, b) in edges {
            drawWorldLine(list: list,
                          frame: frame,
                          a: corners[a],
                          b: corners[b],
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
}

private struct ViewportInfoBar: View {
    let surface: ViewportSurfaceState
    let stats: RenderFrameStats
    let entity: EditorSceneEntitySummary?
    let gizmoMode: EditorGizmoMode
    let gizmoSpace: EditorGizmoSpace
    let shadingMode: EditorViewportShadingMode
    let translateSnapEnabled: Bool
    let rotateSnapEnabled: Bool
    let scaleSnapEnabled: Bool
    let onSelectGizmoMode: (EditorGizmoMode) -> Void
    let onSelectGizmoSpace: (EditorGizmoSpace) -> Void
    let onSelectShadingMode: (EditorViewportShadingMode) -> Void
    let onToggleTranslateSnap: (Bool) -> Void
    let onToggleRotateSnap: (Bool) -> Void
    let onToggleScaleSnap: (Bool) -> Void

    var body: some View {
        let frameMs = Float(stats.cpuFrameTotalNS) / 1_000_000
        let fps = frameMs > 0.001 ? 1_000 / frameMs : 0
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Row(alignment: .center, spacing: 8) {
                Text(surface.isValid
                     ? "\(surface.width) × \(surface.height)"
                     : "Waiting for first render packet")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Spacer(minLength: 0)

                if let entity {
                    Text(entity.name)
                        .font(.caption)
                        .foregroundColor(.onSurface)
                }

                Text(String(format: "FPS: %.1f  Frame: %.2fms", fps, frameMs))
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            }

            Row(alignment: .center, spacing: 6) {
                GizmoButton(label: "Pick", target: .none,
                            current: gizmoMode, onSelect: onSelectGizmoMode)
                GizmoButton(label: "Move", target: .translate,
                            current: gizmoMode, onSelect: onSelectGizmoMode)
                GizmoButton(label: "Rotate", target: .rotate,
                            current: gizmoMode, onSelect: onSelectGizmoMode)
                GizmoButton(label: "Scale", target: .scale,
                            current: gizmoMode, onSelect: onSelectGizmoMode)

                Spacer(minLength: 2)

                ToggleChip(label: "Local", isActive: gizmoSpace == .local) {
                    onSelectGizmoSpace(.local)
                }
                ToggleChip(label: "World", isActive: gizmoSpace == .world) {
                    onSelectGizmoSpace(.world)
                }

                ToggleChip(label: "T Snap", isActive: translateSnapEnabled) {
                    onToggleTranslateSnap(!translateSnapEnabled)
                }
                ToggleChip(label: "R Snap", isActive: rotateSnapEnabled) {
                    onToggleRotateSnap(!rotateSnapEnabled)
                }
                ToggleChip(label: "S Snap", isActive: scaleSnapEnabled) {
                    onToggleScaleSnap(!scaleSnapEnabled)
                }

                Spacer(minLength: 0)

                ToggleChip(label: "Lit", isActive: shadingMode == .lit) {
                    onSelectShadingMode(.lit)
                }
                ToggleChip(label: "Wire", isActive: shadingMode == .wireframe) {
                    onSelectShadingMode(.wireframe)
                }

                Text("Passes: \(stats.passCount)  Draws: \(stats.drawCallCount)")
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            }
        }
        .padding(8)
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
        if isActive {
            Button(label) { onTap() }
                .buttonStyle(.primary)
        } else {
            Button(label) { onTap() }
                .buttonStyle(.secondary)
        }
    }
}

private struct GizmoButton: View {
    let label: String
    let target: EditorGizmoMode
    let current: EditorGizmoMode
    let onSelect: (EditorGizmoMode) -> Void

    var body: some View {
        let isActive = current == target
        if isActive {
            Button(label) { onSelect(target) }
                .buttonStyle(.primary)
        } else {
            Button(label) { onSelect(target) }
                .buttonStyle(.secondary)
        }
    }
}

private struct ViewportIdleCard: View {
    var body: some View {
        Box(direction: .column, alignItems: .center, spacing: 4) {
            Text("Viewport idle")
                .font(.headline)
                .foregroundColor(.onSurface)

            Text("Waiting for the first render packet from the engine.")
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
            Text("Drop to add")
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
