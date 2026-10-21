import EditorCore
import Foundation
import GuavaUI
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat

// The viewport header has two menus, named by what they hold now ("透视",
// "光照"), the way mature viewports group camera and display options instead
// of exposing one control per setting.

/// Camera: projection, axis views, framing, reset and stepwise navigation, all
/// as menu items so the keyboard and assistive technology reach every one.
struct ViewportCameraMenu: View {
    let scene: EditorSceneAdapter
    let isEnabled: Bool
    let canFrameSelection: Bool
    let onSelectProjection: (RenderCamera.Projection) -> Void
    let onSelectAxis: (SIMD3<Float>) -> Void
    let onFrameSelection: () -> Void
    @State private var isPresented = false

    private static let views: [(String, SIMD3<Float>)] = [
        ("Front", SIMD3<Float>(0, 0, -1)), ("Back", SIMD3<Float>(0, 0, 1)),
        ("Right", SIMD3<Float>(-1, 0, 0)), ("Left", SIMD3<Float>(1, 0, 0)),
        ("Top", SIMD3<Float>(0, -1, 0)), ("Bottom", SIMD3<Float>(0, 1, 0)),
    ]

    var body: some View {
        let camera = scene.currentRenderCamera()
        Popover(isPresented: $isPresented, isEnabled: isEnabled, width: 240, surface: .content, overflow: .flip,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            ViewportMenuTrigger(label: label(camera), isActive: camera.projection == .orthographic)
                .accessibility { $0.label = L("Projection"); $0.value = label(camera) }
        } content: {
            Menu(entries(camera), width: 240, maxVisibleRows: 12, onItemActivated: { isPresented = false })
        }
        .debugName("viewport-camera-menu")
    }

    private func label(_ camera: RenderCamera) -> String {
        guard camera.projection == .orthographic else { return L("Perspective") }
        if let view = Self.views.first(where: { matches($0.1, camera) }) { return L(view.0) }
        return L("Orthographic")
    }

    private func matches(_ axis: SIMD3<Float>, _ camera: RenderCamera) -> Bool {
        simd_distance(simd_normalize(camera.target - camera.eye), axis) < 0.001
    }

    private func entries(_ camera: RenderCamera) -> [MenuEntry] {
        let axisViews: [MenuEntry] = Self.views.map { name, axis in
            .item(MenuItem(id: "viewport-view-\(name.lowercased())", title: L(name),
                           isSelected: camera.projection == .orthographic && matches(axis, camera),
                           action: { onSelectAxis(axis) }))
        }
        return [
            .item(MenuItem(id: "viewport-perspective", title: L("Perspective"),
                           isSelected: camera.projection == .perspective,
                           action: { onSelectProjection(.perspective) })),
            .item(MenuItem(id: "viewport-orthographic", title: L("Orthographic"),
                           isSelected: camera.projection == .orthographic,
                           action: { onSelectProjection(.orthographic) })),
            .submenu(MenuSubmenu(id: "viewport-axis-views", title: L("Axis Views"), entries: axisViews)),
            .separator(id: "viewport-camera-frame"),
            .item(MenuItem(id: "viewport-frame-selected", title: L("Frame Selected"), shortcut: "F",
                           isEnabled: canFrameSelection, action: onFrameSelection)),
            .item(MenuItem(id: "viewport-reset-view", title: L("Reset View"), action: { scene.resetViewportView() })),
            .submenu(MenuSubmenu(id: "viewport-step-navigation", title: L("Step Navigation"), entries: stepEntries)),
        ]
    }

    /// Pointer-free orbit, pan and zoom in fixed steps.
    private var stepEntries: [MenuEntry] {
        let frame = EditorViewportDropTarget.frame ?? ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        func steps(_ id: String, _ title: String, _ move: @escaping (Float, Float) -> Void) -> [MenuEntry] {
            [("left", "Left", Float(-1), Float(0)), ("right", "Right", 1, 0), ("up", "Up", 0, -1), ("down", "Down", 0, 1)]
                .map { suffix, direction, x, y in
                    .item(MenuItem(id: "viewport-\(id)-\(suffix)", title: L(title) + " · " + L(direction),
                                   action: { move(x, y) }))
                }
        }
        return steps("orbit", "Orbit") { scene.orbitCamera(deltaScreenX: $0 * 20, deltaScreenY: $1 * 20, in: frame) }
            + [.separator(id: "viewport-step-pan")]
            + steps("pan", "Pan") { scene.panCamera(deltaScreenX: $0 * 40, deltaScreenY: $1 * 40, in: frame) }
            + [.separator(id: "viewport-step-zoom"),
               .item(MenuItem(id: "viewport-zoom-in", title: L("Zoom In"), action: { scene.zoomCamera(factor: 0.8) })),
               .item(MenuItem(id: "viewport-zoom-out", title: L("Zoom Out"), action: { scene.zoomCamera(factor: 1.25) }))]
    }
}

/// Everything about how the scene is drawn.
struct ViewportDisplayState {
    var shading: EditorViewportShadingMode
    var grid: Bool
    var shadows: Bool
    var renderScalePercent: Int
    var interactionDownscale: Bool
    var realtime: Bool
    /// Nil where the Space has no simulation.
    var physics: (options: EditorPhysicsDebugOverlayOptions, scope: EditorPhysicsDebugOverlayScope)?
}

struct ViewportDisplayActions {
    var selectShading: (EditorViewportShadingMode) -> Void
    var toggleGrid: () -> Void
    var toggleShadows: () -> Void
    var selectRenderScale: (Int) -> Void
    var toggleInteractionDownscale: () -> Void
    var toggleRealtime: () -> Void
    var setPhysicsOptions: (EditorPhysicsDebugOverlayOptions) -> Void
    var setPhysicsScope: (EditorPhysicsDebugOverlayScope) -> Void
}

/// Display: shading, overlays, render scale and physics debug layers.
struct ViewportDisplayMenu: View {
    let state: ViewportDisplayState
    let actions: ViewportDisplayActions
    @State private var isPresented = false

    private static let renderScales = [50, 75, 100, 150, 200]

    var body: some View {
        Popover(isPresented: $isPresented, width: 240, surface: .content, overflow: .flip,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            ViewportMenuTrigger(label: Self.label(for: state.shading), isActive: state.shading != .lit)
                .accessibility { $0.label = L("Shading"); $0.value = Self.label(for: state.shading) }
        } content: {
            Menu(entries, width: 240, maxVisibleRows: 14, onItemActivated: { isPresented = false })
        }
        .debugName("viewport-display-menu")
    }

    private var entries: [MenuEntry] {
        let debugViews: [MenuEntry] = [EditorViewportShadingMode.baseColor, .normal, .roughness, .metallic].map(shadingItem)
        var entries: [MenuEntry] = [
            .label(id: "display-shading", title: L("Shading")),
            shadingItem(.lit), shadingItem(.unlit), shadingItem(.wireframe),
            .submenu(MenuSubmenu(id: "display-debug-views", title: L("Debug Views"), entries: debugViews)),
            .separator(id: "display-overlays"),
            .item(MenuItem(id: "display-grid", title: L("Reference Grid"), isSelected: state.grid,
                           action: actions.toggleGrid)),
            .item(MenuItem(id: "display-shadows", title: L("Shadows"), isSelected: state.shadows,
                           action: actions.toggleShadows)),
            .submenu(MenuSubmenu(id: "display-render-scale",
                                 title: L("Render Scale") + " · \(state.renderScalePercent)%",
                                 entries: renderScaleEntries)),
        ]
        if let physics = state.physics {
            entries.append(.submenu(MenuSubmenu(id: "display-physics", title: L("Physics Debug"),
                                                entries: physicsEntries(physics.options, physics.scope))))
        }
        return entries
    }

    private func shadingItem(_ mode: EditorViewportShadingMode) -> MenuEntry {
        .item(MenuItem(id: "viewmode-\(mode.rawValue)", title: Self.label(for: mode),
                       isSelected: state.shading == mode, action: { actions.selectShading(mode) }))
    }

    private var renderScaleEntries: [MenuEntry] {
        Self.renderScales.map { preset in
            .item(MenuItem(id: "renderscale-\(preset)", title: "\(preset)%",
                           isSelected: preset == state.renderScalePercent,
                           action: { actions.selectRenderScale(preset) }))
        } + [
            .separator(id: "renderscale-sep"),
            .item(MenuItem(id: "renderscale-interaction", title: L("Downscale while navigating"),
                           isSelected: state.interactionDownscale, action: actions.toggleInteractionDownscale)),
            .item(MenuItem(id: "renderscale-realtime", title: L("Realtime"),
                           isSelected: state.realtime, action: actions.toggleRealtime)),
        ]
    }

    private func physicsEntries(_ options: EditorPhysicsDebugOverlayOptions,
                                _ scope: EditorPhysicsDebugOverlayScope) -> [MenuEntry] {
        // Each layer names its overlay colour, so the key lives on the toggle.
        func layer(_ id: String, _ title: String, _ color: String, _ option: EditorPhysicsDebugOverlayOptions) -> MenuEntry {
            .item(MenuItem(id: "physics-debug-\(id)", title: title, isSelected: options.contains(option),
                           content: MenuItemContent(detail: color), action: {
                var next = options
                if next.contains(option) { next.remove(option) } else { next.insert(option) }
                actions.setPhysicsOptions(next)
            }))
        }
        return [
            .item(MenuItem(id: "physics-debug-scope-selected", title: L("Selected Entity"),
                           isSelected: scope == .selected, action: { actions.setPhysicsScope(.selected) })),
            .item(MenuItem(id: "physics-debug-scope-scene", title: L("Entire Scene"),
                           isSelected: scope == .scene, action: { actions.setPhysicsScope(.scene) })),
            .separator(id: "physics-debug-scope-separator"),
            layer("shapes", L("Collider Shapes"), L("Cyan"), .shapes),
            layer("bounds", L("AABB / Sleep"), L("Blue"), .bounds),
            layer("contacts", L("Contacts / Normals"), L("Amber"), .contacts),
            layer("joints", L("Joints / Limits"), L("Orange"), .joints),
            layer("characters", L("Character Ground"), L("Green"), .characters),
            .separator(id: "physics-debug-separator"),
            .item(MenuItem(id: "physics-debug-all", title: L("Show All"), isSelected: options == .all,
                           action: { actions.setPhysicsOptions(.all) })),
            .item(MenuItem(id: "physics-debug-none", title: L("Hide All"), isSelected: options.isEmpty,
                           action: { actions.setPhysicsOptions([]) })),
        ]
    }

    static func label(for mode: EditorViewportShadingMode) -> String {
        switch mode {
        case .lit: return L("Lit")
        case .unlit: return L("Unlit")
        case .baseColor: return L("Base Color")
        case .normal: return L("Normal")
        case .roughness: return L("Roughness")
        case .metallic: return L("Metallic")
        case .wireframe: return L("Wireframe")
        }
    }
}
