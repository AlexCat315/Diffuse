import EditorCore
import CoveUI
import CoveUIRuntime

struct MeshLoopCutControls: View {
    let model: EditorMeshEditing

    var body: some View {
        Row(alignment: .center,spacing: 4) {
            ShortcutHost(route: .overlay,onKeyDown: { key in
                guard key.scancode == 41 else { return false }
                _ = model.cancelLoopCut(); return true
            })
            NumberField(value: Binding(get: { Float(model.loopCutCount) },set: {
                _ = model.previewLoopCut(cuts: Int($0.rounded()),slide: model.loopCutSlide)
            }),decimals: 0,size: .small,minValue: 1,maxValue: 32,step: 1,prefix: .init("#"))
                .frame(width: 44).tooltip(L("Number of Cuts"))
                .accessibility { $0.label = L("Number of Cuts") }.debugName("mesh-loop-cut-count")
            NumberField(value: Binding(get: { model.loopCutSlide },set: {
                _ = model.previewLoopCut(cuts: model.loopCutCount,slide: $0)
            }),decimals: 3,size: .small,minValue: -0.99,maxValue: 0.99,step: 0.05,prefix: .init("↔"))
                .frame(width: 64).border(model.isLoopCutPreviewValid ? .divider : .error,width: 1)
                .tooltip(L("Loop Slide")).accessibility { $0.label = L("Loop Slide") }.debugName("mesh-loop-cut-slide")
            Button(icon: .resource(UIIcons.Action.check),size: 14,isEnabled: model.isLoopCutPreviewValid,
                   tooltip: L("Confirm Loop Cut"),action: { _ = model.commitLoopCut() })
                .buttonStyle(.ghost).frame(width: 22,height: 28).debugName("mesh-loop-cut-confirm")
            Button(icon: .resource(UIIcons.Action.x),size: 14,tooltip: L("Cancel Loop Cut"),
                   action: { _ = model.cancelLoopCut() })
                .buttonStyle(.ghost).frame(width: 22,height: 28).debugName("mesh-loop-cut-cancel")
        }.debugName("mesh-loop-cut-controls")
    }
}
