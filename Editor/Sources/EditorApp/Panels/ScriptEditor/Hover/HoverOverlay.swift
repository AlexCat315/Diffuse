import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// The same coordinate tooltip used by controls and diagnostic messages owns
/// viewport fitting, clipping escape and node-lifetime cleanup.
struct ScriptHoverOverlay: View {
    let presentation: ScriptEditorHoverPresentation
    var body: some View {
        if let anchor = presentation.anchor, !presentation.textBlocks.isEmpty {
            Tooltip(anchor: .point(CGPoint(x: CGFloat(anchor.windowX), y: CGFloat(anchor.windowY))),
                    configure: { $0.maxWidth = 460; $0.gap = 18 }) {
                Column(alignment: .leading, spacing: 6) {
                    for block in presentation.textBlocks { textBlock(block) }
                }.padding(horizontal: 10, vertical: 8)
                    .background(.surfaceFloating).border(.border, width: 1).cornerRadius(6)
            }
        }
    }
    private func textBlock(_ block: ScriptHoverTextBlock) -> AnyView {
        if block.role == .signature {
            return AnyView(Text(block.text, lineLimit: 8).font(.mono).foregroundColor(.onSurface))
        }
        return AnyView(Text(block.text, lineLimit: 12).font(.caption).foregroundColor(.onSurfaceMuted))
    }
}
