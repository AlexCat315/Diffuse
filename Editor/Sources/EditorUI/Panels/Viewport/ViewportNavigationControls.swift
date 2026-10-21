import EditorCore
import Foundation
import GuavaUI
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat

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
            Popover(isPresented: $isPresented, isEnabled: isEnabled, width: 280, surface: .content, overflow: .flip,
                    onKey: viewportPopoverDismissOnEscape($isPresented)) {
                ViewportMenuTrigger(icon: UIIcons.Shape.pin, isActive: translate || rotate || scale)
                    .tooltip(L("Snapping"))
                    .accessibility { $0.label = L("Snapping") }
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
