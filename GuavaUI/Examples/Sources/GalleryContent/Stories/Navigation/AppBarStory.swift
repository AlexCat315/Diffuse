import GuavaUI
import GuavaUIRuntime

struct AppBarStory: View {
    let options: GalleryOptions
    @State private var longTitle = true
    @State private var textPrimary = false
    @State private var lastAction = "No action yet"
    var body: some View {
        StorySection("Application header", "Resize the window: compact headers keep the primary action and a menu; wider headers show up to three actions. The complete title remains available to assistive technology and in a tooltip.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $longTitle, isEnabled: options.isEnabled)
                        .accessibilityLabel("Long title").debugName("appbar-long-title")
                    Text("Long title").font(.caption).flex(1, shrink: 1).frame(minWidth: 0).accessibilityHidden()
                }.flex(0, shrink: 1).frame(minWidth: 0)
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $textPrimary, isEnabled: options.isEnabled)
                        .accessibilityLabel("Text primary action").debugName("appbar-text-primary")
                    Text("Text primary action").font(.caption).flex(1, shrink: 1).frame(minWidth: 0).accessibilityHidden()
                }.flex(0, shrink: 1).frame(minWidth: 0)
            }
            AppBar(longTitle ? "Workspace permissions and project access · 用户设置 👩🏽‍💻" : "Workspace",
                   subtitle: "All changes saved locally", back: MenuItem(id: "back", title: "Back to projects") { lastAction = "Back" },
                   primary: ToolbarItem(MenuItem(id: "save", title: "Save workspace") { lastAction = "Saved" },
                       icon: textPrimary ? nil : .resource(UIIcons.Action.check)),
                   actions: actions, configure: { $0.isEnabled = options.isEnabled })
                .border(.border, width: 1).cornerRadius(.panelRadius).debugName("gallery-appbar")
            Text(lastAction).font(.caption).foregroundColor(.onSurfaceMuted).debugName("appbar-result")
        }
        StorySection("Host safe area", "The host consumes the top and side insets once. The application bar does not add a second status-bar inset.") {
            SafeArea {
                SafeArea {
                    AppBar("Mobile workspace", subtitle: "Navigation and actions",
                           back: MenuItem(id: "safe-back", title: "Back") { lastAction = "Safe-area back" },
                           primary: ToolbarItem(MenuItem(id: "safe-save", title: "Save") { lastAction = "Safe-area save" }, icon: .resource(UIIcons.Action.check)),
                           configure: { $0.isEnabled = options.isEnabled })
                        .debugName("appbar-safe-content")
                }
            }.safeAreaInsets(EdgeInsets(top: 24, leading: 12, bottom: 0, trailing: 12))
                .background(.surfaceVariant).border(.border, width: 1).debugName("appbar-safe-host")
        }
    }
    private var actions: [ToolbarItem] {
        [
            ToolbarItem(MenuItem(id: "find", title: "Find in workspace") { lastAction = "Find" }, icon: .resource(UIIcons.Action.search), placement: .automatic(priority: 10)),
            ToolbarItem(MenuItem(id: "export", title: "Export project") { lastAction = "Exported" }, icon: .resource(UIIcons.Action.download)),
            ToolbarItem(MenuItem(id: "share", title: "Share project") { lastAction = "Shared" }, icon: .resource(UIIcons.Action.share)),
            ToolbarItem(MenuItem(id: "pin", title: "Pinned", isSelected: true) { lastAction = "Pinned" }, placement: .overflow),
            ToolbarItem(MenuItem(id: "unavailable", title: "Unavailable", isEnabled: false) {}, placement: .overflow)
        ]
    }
}
