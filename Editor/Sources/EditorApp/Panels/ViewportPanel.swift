import EditorCore
import EngineKernel
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

            // 推送 gizmo 控制器所需的快照（摄像机 / 视口矩形 / 实体世界坐标）。
            let _: Void = updateGizmoSnapshot(selectedID: store.state.selectedEntityID,
                                              gizmoMode: gizmoMode,
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
                             drawGizmoOverlay(list: list, frame: frame, mode: gizmoMode,
                                              selectedID: store.state.selectedEntityID)
                         }) {
                Box(direction: .column, alignItems: .stretch) {
                    ViewportInfoBar(surface: surface,
                                    stats: stats,
                                    entity: entity,
                                    gizmoMode: gizmoMode,
                                    onSelectGizmoMode: { mode in
                                        if store.state.gizmoMode != mode {
                                            store.dispatch(.setGizmoMode(mode))
                                        }
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
                scene.setEntityLocalMatrix(drag.entityID, to: newMatrix)
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
                return
            }
            if app.store.state.activeAssetDrag != nil {
                _ = app.handleAssetDrop(at: button.x, cursorY: button.y)
                viewport.leftDownAt = nil
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
            if let mode = gizmoMode(for: key.keycode) {
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
                                     surface: ViewportSurfaceState) {
        guard let mode = controllerMode(for: gizmoMode),
              let id = selectedID,
              let world = scene.entityWorldPosition(id),
              let local = scene.entityLocalMatrix(id),
              let frame = EditorViewportDropTarget.frame,
              frame.width > 0, frame.height > 0
        else {
            EditorGizmoController.shared.updateSnapshot(nil)
            return
        }
        let camera = scene.currentRenderCamera()
        let dist = simd_length(world - camera.eye)
        let axisLength = max(0.4, dist * 0.18)
        let parentWorld = scene.entityParentWorldMatrix(id)
        EditorGizmoController.shared.updateSnapshot(
            EditorGizmoController.Snapshot(
                mode: mode,
                camera: camera,
                frame: frame,
                drawableWidth: Float(surface.width),
                drawableHeight: Float(surface.height),
                entityID: id,
                entityWorldPosition: world,
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
                                  selectedID: UInt64?) {
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
            let tipWorld = snap.entityWorldPosition + axis.worldDirection * snap.axisLength
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
            let (basisU, basisV) = axis.planeBasis
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
            let (u, v) = plane.basis
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

    private func gizmoMode(for keycode: UInt32) -> EditorGizmoMode? {
        switch keycode {
        case 0x71 /* q */: return EditorGizmoMode.none
        case 0x77 /* w */: return .translate
        case 0x65 /* e */: return .rotate
        case 0x72 /* r */: return .scale
        default: return nil
        }
    }
}

private struct ViewportInfoBar: View {
    let surface: ViewportSurfaceState
    let stats: RenderFrameStats
    let entity: EditorSceneEntitySummary?
    let gizmoMode: EditorGizmoMode
    let onSelectGizmoMode: (EditorGizmoMode) -> Void

    var body: some View {
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

                Spacer(minLength: 0)

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
