import EditorCore
import GuavaUI

/// Applies the editor's presentation tokens to everything below it.
///
/// `refreshRevision` is the only thing that rebuilds the subtree: a theme or
/// language change arrives through `ThemeEnvironment` instead, which repaints
/// the layers that resolve a token without remounting or re-measuring them.
struct EditorPresentationBoundary<Content: View>: View {
    let presentation: EditorPresentationState
    let content: Content

    init(presentation: EditorPresentationState,
         @ViewBuilder content: () -> Content) {
        self.presentation = presentation
        self.content = content()
    }

    var body: some View {
        content
            .id(presentation.refreshRevision)
            .theme(EditorVisualTheme.make(dark: presentation.themeMode == .dark))
            .controlSize(.small)
    }
}
