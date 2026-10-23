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
    let theme: Theme?

    init(presentation: EditorPresentationState,
         theme: Theme? = nil,
         @ViewBuilder content: () -> Content) {
        self.presentation = presentation
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        content
            .id(presentation.refreshRevision)
            .theme(theme ?? EditorVisualTheme.make(dark: presentation.themeMode == .dark, themeID: presentation.themeID))
            .controlSize(.small)
    }
}
