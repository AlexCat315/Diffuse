internal import CoveUI
internal import CoveUIRuntime

/// Paints chrome that hosts its own `.surface` background (the immersive
/// title bar) on the window canvas, so only panes read as raised blocks.
struct EditorCanvasChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ThemeReader { theme in
            var canvas = theme
            canvas.colors.surface = theme.colors.background
            return content().theme(canvas)
        }
    }
}
