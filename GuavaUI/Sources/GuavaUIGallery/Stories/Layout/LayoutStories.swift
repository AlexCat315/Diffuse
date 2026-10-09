import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace

struct PanelStory: View {
    var body: some View {
        StorySection("Panel slots", "Panel owns chrome; the application supplies a title, accessory and content.") {
            Box(direction: .row, alignItems: .stretch, spacing: 16) {
                Panel("Inspector", isActive: true, accessory: { Badge("3 properties", tone: .info) }, content: {
                    Text("Active panel content").padding(24)
                }).flex(1, shrink: 1, basis: 0)
                Panel("Console") { Text("Inactive panel content").padding(24) }.flex(1, shrink: 1, basis: 0)
            }.frame(height: 180)
        }
    }
}

struct SplitStory: View {
    @State private var fraction = 0.4
    var body: some View {
        StorySection("Proportional split", "The slider updates the fraction. Draggable split handles live in Workspace.") {
            Slider(value: $fraction, range: 0.1...0.9)
            SplitView(.horizontal, fraction: Float(fraction), first: {
                Text("Leading").padding(24).background(.surfaceVariant)
            }, second: {
                SplitView(.vertical, first: { Text("Top").padding(20) }, second: { Text("Bottom").padding(20).background(.surfaceVariant) })
            }).frame(height: 210)
        }
    }
}

struct ScrollStory: View {
    var body: some View {
        StorySection("Nested scroll surfaces", "The inner viewport consumes wheel input while it can move; the outer viewport receives overflow.") {
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    for i in 0..<40 { AnyView(Text("Scrollable line \(i + 1)").font(.body).padding(10).background(i % 2 == 0 ? .surfaceVariant : .surface)) }
                }.flex(0, shrink: 0)
            }.frame(height: 280)
        }
    }
}

struct BoundedScrollStory: View {
    @State private var count = 3
    var body: some View {
        StorySection("Bounded content height", "The viewport grows from 90 to 240 points, then scrolls.") {
            Select(selection: $count, options: [3, 6, 20].map { SelectOption(value: $0, label: "\($0) rows") }).frame(width: 180)
            BoundedScrollView(contentHeight: Float(count) * 30, minHeight: 90, maxHeight: 240) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    for i in 0..<count { AnyView(Text("Row \(i + 1)").font(.body).frame(height: 30).padding(horizontal: 10)) }
                }
            }.border(.border, width: 1)
        }
    }
}

struct PropertyGridStory: View {
    let options: GalleryOptions
    @State private var name: TextBuffer = "Main Camera"
    @State private var exposure: Float = 1.2
    @State private var visible = true
    var body: some View {
        StorySection("Inspector", "Typed controls occupy value slots; section and row sizing belongs to the grid.") {
            PropertyGrid([
                PropertyGridSection(id: "identity", title: "Identity", rows: [
                    PropertyGridRow(id: "name", label: "Name") { TextField("Name", text: $name) { $0.behavior.disabled = !options.isEnabled } },
                    PropertyGridRow(id: "visible", label: "Visible") { Toggle(isOn: $visible, isEnabled: options.isEnabled) }
                ], isCollapsible: true),
                PropertyGridSection(id: "camera", title: "Camera", rows: [
                    PropertyGridRow(id: "exposure", label: "Exposure") { NumberField(value: $exposure, isEnabled: options.isEnabled, minValue: 0, maxValue: 8, step: 0.1) }
                ], isCollapsible: true)
            ], minValueWidth: 200).frame(height: 270)
            PropertyGrid([], emptyText: "Select an object to inspect its properties").frame(height: 70)
        }
    }
}

struct WorkspaceStory: View {
    @State private var controller = WorkspaceController(document: Self.defaultDocument())
    @State private var saved: Data? = nil
    @State private var status = "Drag a tab or a split divider"
    static func defaultDocument() -> WorkspaceDocument {
        WorkspaceDocument(panels: [
            "files": WorkspacePanel(id: "files", title: "Files"),
            "editor": WorkspacePanel(id: "editor", title: "Editor", isClosable: false, isCollapsible: false),
            "preview": WorkspacePanel(id: "preview", title: "Preview")
        ], groups: [
            "left": WorkspaceTabGroup(id: "left", panels: ["files"], activePanelID: "files"),
            "main": WorkspaceTabGroup(id: "main", panels: ["editor", "preview"], activePanelID: "editor")
        ], slots: WorkspaceSlot.standardEditorSlots(leading: .group("left"), center: .group("main")),
           layoutTree: .group("main"), splitFractions: WorkspaceSplitFractions(leading: 0.25))
    }
    var body: some View {
        StorySection("Dock workspace", "Save a serialized document, rearrange panels, then restore it. Reset restores the authored layout.") {
            Row(alignment: .center, spacing: 10) {
                Button("Save layout") {
                    do { saved = try JSONEncoder().encode(controller.document); status = "Layout saved" }
                    catch { status = "Save failed: \(error.localizedDescription)" }
                }.buttonStyle(.secondary)
                Button("Restore", isEnabled: saved != nil) {
                    guard let saved else { return }
                    do { controller.replace(try JSONDecoder().decode(WorkspaceDocument.self, from: saved)); status = "Layout restored" }
                    catch { status = "Restore failed: \(error.localizedDescription)" }
                }.buttonStyle(.secondary)
                Button("Reset") { controller.replace(Self.defaultDocument()); status = "Layout reset" }.buttonStyle(.ghost)
            }
            WorkspaceView(controller: controller) { id in
                AnyView(Text(id == "files" ? "Sources\nResources\nTests" : id == "editor" ? "Editable document workspace" : "Preview panel").padding(18))
            }.frame(height: 360).border(.border, width: 1)
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct LayoutStory: View {
    var body: some View {
        StorySection("Flex layout", "Layout containers arrange children; spacing and alignment belong to the owning container.") {
            Row(alignment: .center, spacing: 12) {
                Badge("Leading", tone: .info); Spacer(); Badge("Trailing", tone: .success)
            }.padding(12).background(.surfaceVariant).cornerRadius(6)
            Divider()
            Box(direction: .row, alignItems: .stretch, spacing: 12) {
                for i in 1...3 { AnyView(Text("Column \(i)").padding(24).background(.surfaceVariant).cornerRadius(6).flex(Float(i), shrink: 1, basis: 0)) }
            }
        }
    }
}

struct AnimationStory: View {
    @State private var visible = true
    var body: some View {
        StorySection("Animated visibility", "The component retains the subtree through its exit animation and cleans up after settling.") {
            Button(visible ? "Hide content" : "Show content") { visible.toggle() }.buttonStyle(.secondary)
            AnimatedVisibility(isVisible: visible, transition: .opacity.combined(with: .move(edge: .top, distance: 12))) {
                Alert("Animated content", message: "Try toggling repeatedly during the transition.", tone: .success)
            }
        }
    }
}

struct ThemeStory: View {
    var body: some View {
        ThemeReader { theme in
            Box(direction: .column, alignItems: .stretch, spacing: 24) {
                StorySection("Surfaces", "Semantic tokens describe roles; change the theme using the sidebar.") {
                    Row(alignment: .center, spacing: 12) {
                        Text("Background").padding(16).background(.background).border(.border, width: 1)
                        Text("Surface").padding(16).background(.surface).border(.border, width: 1)
                        Text("Variant").padding(16).background(.surfaceVariant)
                        Text("Floating").padding(16).background(.surfaceFloating).border(.border, width: 1)
                    }
                    Row(alignment: .center, spacing: 10) { for tone in StatusTone.allCases { Badge(String(describing: tone).capitalized, tone: tone) } }
                }
                StorySection("Typography", "The same hierarchy uses each theme's font and line-height tokens.") {
                    Text("Display").font(.display)
                    Text("Title").font(.title)
                    Text("Headline").font(.headline)
                    Text("Body text").font(.body)
                    Text("Caption and secondary information").font(.caption).foregroundColor(.onSurfaceMuted)
                    Text("let value = 42").font(.mono)
                    Text("Base spacing: \(theme.spacing.sm) pt").font(.caption).foregroundColor(.onSurfaceMuted)
                }
                StorySection("Multilingual text & emoji", "Chinese, accented names and emoji share one line. Text size and opacity apply consistently.") {
                    Text("Émile · 中文 · 🙂 👩🏽‍💻 🇨🇳 ❤️").font(.system(size: 14)).lineHeight(22)
                    Text("Émile · 中文 · 🙂 👩🏽‍💻 🇨🇳 ❤️").font(.system(size: 24)).lineHeight(36)
                    Text("中文 🙂 👨‍👩‍👧‍👦").font(.system(size: 40)).lineHeight(58)
                    Text("Colored text 🙂 👩🏽‍💻 keeps its emoji colors").font(.system(size: 20))
                        .foregroundColor(Color(r: 0.8, g: 0.15, b: 0.2)).lineHeight(30)
                    Text("Half opacity 🙂 👩🏽‍💻").font(.system(size: 20)).lineHeight(30).opacity(0.5)
                }
            }
        }
    }
}
