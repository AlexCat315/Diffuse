import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat

struct ViewportProjectionSelector: View {
    let camera: RenderCamera
    let isEnabled: Bool
    let onSelectProjection: (RenderCamera.Projection) -> Void
    let onSelectAxis: (SIMD3<Float>) -> Void
    @State private var isPresented = false

    private static let views: [(String, SIMD3<Float>)] = [
        ("Front", SIMD3<Float>(0, 0, -1)), ("Back", SIMD3<Float>(0, 0, 1)),
        ("Right", SIMD3<Float>(-1, 0, 0)), ("Left", SIMD3<Float>(1, 0, 0)),
        ("Top", SIMD3<Float>(0, -1, 0)), ("Bottom", SIMD3<Float>(0, 1, 0)),
    ]

    var body: some View {
        Popover(isPresented: $isPresented, isEnabled: isEnabled, width: 180,
                onKey: viewportPopoverDismissOnEscape($isPresented)) {
            Row(alignment: .center, spacing: 5) {
                Text(label, lineLimit: 1).font(.caption)
                Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
            }
            .padding(horizontal: 8)
            .frame(height: 24)
            .background(.surfaceSunken)
            .cornerRadius(4)
        } content: {
            Menu(menuEntries, width: 180, maxVisibleRows: 11,
                 onItemActivated: { isPresented = false })
        }
        .debugName("viewport-projection-selector")
    }

    private var label: String {
        guard camera.projection == .orthographic else { return L("Perspective") }
        if let view = Self.views.first(where: { matches($0.1) }) {
            return "\(L("Orthographic")) · \(L(view.0))"
        }
        return L("Orthographic")
    }

    private func matches(_ axis: SIMD3<Float>) -> Bool {
        simd_distance(simd_normalize(camera.target - camera.eye), axis) < 0.001
    }

    private var menuEntries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(MenuItem(id: "viewport-perspective", title: L("Perspective"),
                           isEnabled: isEnabled, isSelected: camera.projection == .perspective,
                           action: { onSelectProjection(.perspective) })),
            .item(MenuItem(id: "viewport-orthographic", title: L("Orthographic"),
                           isEnabled: isEnabled, isSelected: camera.projection == .orthographic,
                           action: { onSelectProjection(.orthographic) })),
            .separator(id: "viewport-projection-separator"),
        ]
        entries += Self.views.map { name, axis in
            .item(MenuItem(id: "viewport-view-\(name.lowercased())", title: L(name),
                           isEnabled: isEnabled,
                           isSelected: camera.projection == .orthographic && matches(axis),
                           action: { onSelectAxis(axis) }))
        }
        return entries
    }
}

struct ViewportSnapSelector: View {
    let store: EditorStore
    let isEnabled: Bool
    @State private var isPresented = false

    var body: some View {
        StoreScope(store) { observed in
            let translate = observed.translateSnapEnabled
            let rotate = observed.rotateSnapEnabled
            let scale = observed.scaleSnapEnabled
            let _ = observed.translateSnapStep
            let _ = observed.rotateSnapStepDegrees
            let _ = observed.scaleSnapStep
            Popover(isPresented: $isPresented, isEnabled: isEnabled, width: 280,
                    onKey: viewportPopoverDismissOnEscape($isPresented)) {
                Row(alignment: .center, spacing: 5) {
                    Text(L("Snapping"), lineLimit: 1).font(.caption)
                        .foregroundColor(translate || rotate || scale ? .accent : .onSurface)
                    Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
                }
                .padding(horizontal: 8)
            .frame(height: 24)
                .background(.surfaceSunken)
                .cornerRadius(4)
            } content: {
                Column(alignment: .leading, spacing: 8) {
                    Text(L("Snap Steps")).font(.caption).foregroundColor(.onSurfaceMuted)
                    snapRow(id: "translate", label: L("Move"), enabled: translate,
                            value: Binding(get: { observed.translateSnapStep },
                                           set: { observed.dispatch(.setTranslateSnapStep($0)) }),
                            maximum: 10_000, suffix: L("World Units"),
                            onToggle: { observed.dispatch(.setTranslateSnapEnabled(!translate)) })
                    snapRow(id: "rotate", label: L("Rotate"), enabled: rotate,
                            value: Binding(get: { observed.rotateSnapStepDegrees },
                                           set: { observed.dispatch(.setRotateSnapStepDegrees($0)) }),
                            maximum: 180, suffix: "°",
                            onToggle: { observed.dispatch(.setRotateSnapEnabled(!rotate)) })
                    snapRow(id: "scale", label: L("Scale"), enabled: scale,
                            value: Binding(get: { observed.scaleSnapStep },
                                           set: { observed.dispatch(.setScaleSnapStep($0)) }),
                            maximum: 10, suffix: L("Scale Increment"),
                            onToggle: { observed.dispatch(.setScaleSnapEnabled(!scale)) })
                }
                .padding(10)
            }
            .debugName("viewport-snap-selector")
        }
    }

    private func snapRow(id: String, label: String, enabled: Bool, value: Binding<Float>,
                         maximum: Float, suffix: String,
                         onToggle: @escaping () -> Void) -> some View {
        Row(alignment: .center, spacing: 8) {
            Button(label, isEnabled: isEnabled, isSelected: enabled, action: onToggle)
                .buttonStyle(.toggle)
                .frame(width: 54)
                .debugName("viewport-snap-\(id)-toggle")
            NumberField(value: value, decimals: 3,
                        isEnabled: isEnabled, minValue: 0.001, maxValue: maximum)
                .frame(width: 82)
                .debugName("viewport-snap-\(id)-step")
            Text(suffix, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
