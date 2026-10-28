import EditorCore
import CoveUI
import CoveUIRuntime

struct MeshInsetControls: View {
    let model: EditorMeshEditing

    var body: some View {
        Row(alignment: .center,spacing: 4) {
            ShortcutHost(route: .overlay,onKeyDown: { key in
                guard key.scancode == 41 else { return false }
                _ = model.cancelInset()
                return true
            })
            Image(resource: UIIcons.Shape.square,width: 16,height: 16)
                .tooltip(L("Inset Individual Faces"))
            NumberField(value: Binding(get: { model.insetDistance },set: { _ = model.previewInset(distance: $0) }),
                        decimals: 4,minValue: 0,maxValue: 100_000)
                .frame(width: 82)
                .border(model.isInsetPreviewValid ? .divider : .error,width: 1)
                .tooltip(L(model.isInsetPreviewValid ? "Inset Width" : "Inset width collapses the face"))
                .accessibility { $0.label = L("Inset Width") }
                .debugName("mesh-inset-width")
            Button(icon: .resource(UIIcons.Action.check),size: 14,isEnabled: model.isInsetPreviewValid,
                   tooltip: L("Confirm Inset"),action: { _ = model.commitInset() })
                .buttonStyle(.ghost).frame(width: 26,height: 28).debugName("mesh-inset-confirm")
            Button(icon: .resource(UIIcons.Action.x),size: 14,tooltip: L("Cancel Inset"),
                   action: { _ = model.cancelInset() })
                .buttonStyle(.ghost).frame(width: 26,height: 28).debugName("mesh-inset-cancel")
        }
        .debugName("mesh-inset-controls")
    }
}
