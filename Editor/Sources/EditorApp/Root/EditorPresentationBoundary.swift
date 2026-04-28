import EditorCore
import GuavaUICompose

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
            .id(presentation.revision)
            .appearance(presentation.themeMode == .dark ? .dark : .light)
    }
}
