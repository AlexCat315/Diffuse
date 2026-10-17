import Foundation
import GuavaUI
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
    @State private var resizable: Float = 0.35
    @State private var draft: TextBuffer = "This draft survives pane switches"
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Proportional split", "The slider updates the fraction; the divider is a plain separator because the application owns the layout.") {
                Slider(value: $fraction, range: 0.1...0.9)
                SplitView(.horizontal, fraction: Float(fraction), first: {
                    Text("Leading").padding(24).background(.surfaceVariant)
                }, second: {
                    SplitView(.vertical, first: { Text("Top").padding(20) }, second: { Text("Bottom").padding(20).background(.surfaceVariant) })
                }).frame(height: 210)
            }
            StorySection("Resizable and compact split", "Below 600 points of container width, choose one pane with the tabs. Widen to restore both panes and the requested fraction. Drafts and scroll positions survive the switch; use arrows, Home and End on the tabs.") {
                SplitView(.horizontal, fraction: $resizable,
                    constraints: .init(fraction: 0.2...0.75, minimumFirst: 150, minimumSecond: 220),
                    compact: .init(firstTitle: "Sidebar", secondTitle: "Content"), first: {
                    Text("Sidebar").padding(24).background(.surfaceVariant)
                }, second: {
                    Box(direction: .column, alignItems: .stretch, spacing: 12) {
                        TextField("Document title", text: $draft)
                        ScrollView(.vertical) {
                            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                                for index in 1...20 { AnyView(Text("Content line \(index)").padding(8)) }
                            }.flex(0, shrink: 0)
                        }.flex(1, shrink: 1, basis: 0)
                    }.padding(12).background(.surface)
                }).frame(height: 270).debugName("gallery-adaptive-split")
                Text("Fraction: \(Int(resizable * 100))% · 20–75% · pane minimums 150 / 220pt").font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
    }
}

struct ScrollStory: View {
    var body: some View {
        StorySection("Native scroll stream", "Trackpad points and OS momentum are followed directly; wheel lines move by 30pt. No extra fling is inferred after input stops. At an edge, outward input passes to the outer viewport.") {
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    for i in 0..<40 { AnyView(Text("Scrollable line \(i + 1)").font(.body).padding(10).background(i % 2 == 0 ? .surfaceVariant : .surface)) }
                }.flex(0, shrink: 0)
            }.frame(height: 280).debugName("scroll-lab-viewport")
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
            "files": WorkspacePanel(id: "files", title: "Files", sizing: .init(width: .init(minimum: 160, preferred: 240, maximum: 340))),
            "search": WorkspacePanel(id: "search", title: "Search across the entire workspace", sizing: .init(width: .init(minimum: 180, preferred: 260, maximum: 360))),
            "history": WorkspacePanel(id: "history", title: "Version history and incoming changes"),
            "editor": WorkspacePanel(id: "editor", title: "Editor", isClosable: false, isCollapsible: false),
            "preview": WorkspacePanel(id: "preview", title: "Preview", sizing: .init(height: .init(minimum: 80, preferred: 140, maximum: 240)))
        ], groups: [
            "left": WorkspaceTabGroup(id: "left", panels: ["files", "search", "history"], activePanelID: "files"),
            "main": WorkspaceTabGroup(id: "main", panels: ["editor"], activePanelID: "editor"),
            "preview": WorkspaceTabGroup(id: "preview", panels: ["preview"], activePanelID: "preview")
        ], slots: WorkspaceSlot.standardEditorSlots(leading: .group("left"), center:
            .split(axis: .vertical, fraction: 0.58, first: .group("main"), second: .group("preview"))),
           splitFractions: WorkspaceSplitFractions())
    }
    var body: some View {
        StorySection("Dock workspace", "Every panel owns persistent minimum, preferred and maximum sizes. Focus any divider for arrow/Home/End adjustment. Overflowing tabs scroll horizontally, including at 200%. Save and restore persists authored sizes and user splits.") {
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
                AnyView(Text(id == "files" ? "Sources\nResources\nTests" : id == "editor" ? "Editable document workspace" : id == "search" ? "Search panel" : id == "history" ? "Version history" : "Preview panel").padding(18))
            }.frame(height: 360)
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct LayoutStory: View {
    let options: GalleryOptions
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
          StorySection("Flex layout", "Layout containers arrange children; spacing and alignment belong to the owning container.") {
            Row(alignment: .center, spacing: 12) {
                Badge("Leading", tone: .info); Spacer(); Badge("Trailing", tone: .success)
            }.padding(12).background(.surfaceVariant).cornerRadius(6)
            Divider()
            Box(direction: .row, alignItems: .stretch, spacing: 12) {
                for i in 1...3 { AnyView(Text("Column \(i)").padding(24).background(.surfaceVariant).cornerRadius(6).flex(Float(i), shrink: 1, basis: 0)) }
            }
          }
          LayoutFoundationExamples(options: options)
        }
    }
}

struct AnimationStory: View {
    let options: GalleryOptions
    @State private var visible = true
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Animated visibility", "The component retains the subtree through its exit animation and cleans up after settling.") {
                Button(visible ? "Hide content" : "Show content", isEnabled: options.isEnabled) { visible.toggle() }.buttonStyle(.secondary)
                AnimatedVisibility(isVisible: visible, transition: .opacity.combined(with: .move(edge: .top, distance: 12))) {
                    Alert("Animated content", message: "Try toggling repeatedly during the transition.", tone: .success)
                }
            }
            AnimationCurveExamples(isEnabled: options.isEnabled)
            AnimationSystemExamples(isEnabled: options.isEnabled)
        }
    }
}

struct StatusBarStory: View {
    let options: GalleryOptions
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Window footer", "Every cell shares one height, so swapping a branch name for a build state never reflows the content above.") {
                Column(spacing: 0) {
                    Box(direction: .column, alignItems: .center, justifyContent: .center) {}
                        .frame(height: 84)
                        .background(.surface)
                    StatusBar(isEnabled: options.isEnabled) {
                        StatusBarText("main", icon: UIIcons.Editor.gitBranch)
                        StatusBarText("UTF-8", isMonospaced: true)
                        StatusBarText("2 warnings", tone: .warning)
                        StatusBarText("Spaces", detail: "2")
                    } trailing: {
                        StatusBarText("Ln 12", detail: "Col 4", isMonospaced: true)
                        StatusBarText("Connected", tone: .success)
                    }
                }
                .border(.border, width: 1)
                .cornerRadius(8)
                .clipped()
            }
            StorySection("Single slot", "A bar with only trailing cells still keeps its hairline and height; leading and trailing are both optional.") {
                StatusBar(showsDivider: false, isEnabled: options.isEnabled) {
                    StatusBarText("Indexing", detail: "1,204 files", icon: UIIcons.File.fileCode)
                } trailing: {
                    StatusBarText("Disconnected", tone: .danger)
                }
                .border(.border, width: 1)
                .cornerRadius(8)
            }
        }
    }
}

struct CarouselStory: View {
    let options: GalleryOptions
    @State private var page = "themes"
    @State private var showsArrows = true
    @State private var showsIndicators = true
    @State private var allowsWrap = true

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Paged content", "Tap the page action or drag horizontally across it. A swipe cancels the button press and changes one page on release; vertical movement does not page. Left/Right/Home/End also navigate.") {
                Carousel(pages: Self.pages, selection: $page) {
                    $0.isEnabled = options.isEnabled
                    $0.showsArrows = showsArrows
                    $0.showsIndicators = showsIndicators
                    $0.allowsWrap = allowsWrap
                    $0.height = 176
                }
                Row(alignment: .center, spacing: 16) {
                    Checkbox(isOn: $showsArrows, isEnabled: options.isEnabled); Text("Arrows").font(.caption)
                    Checkbox(isOn: $showsIndicators, isEnabled: options.isEnabled); Text("Indicators").font(.caption)
                    Checkbox(isOn: $allowsWrap, isEnabled: options.isEnabled); Text("Wrap").font(.caption)
                    Text("Page: \(page)").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            StorySection("No wrap, no chrome", "Onboarding flows end where the last page ends: wrapping off, controls reduced to the indicators.") {
                Carousel(pages: Self.pages) {
                    $0.isEnabled = options.isEnabled
                    $0.showsArrows = false
                    $0.allowsWrap = false
                    $0.height = 120
                }
            }
            StorySection("Empty collection", "An empty carousel has no page action or keyboard stop. A missing selection falls back to the first available page without rewriting the binding.") {
                Carousel<String>(pages: []) { $0.height = 72 }
            }
        }
    }

    private static var pages: [CarouselPage<String>] {[
        CarouselPage("welcome", caption: "Welcome — start with the component catalog") {
            CarouselCard("Welcome", detail: "GuavaUI is declarative, themed and testable.", tint: Color(r: 0.30, g: 0.55, b: 0.95))
        },
        CarouselPage("themes", caption: "Themes — semantic tokens, light and dark") {
            CarouselCard("Themes", detail: "Colours describe roles, never raw values.", tint: Color(r: 0.42, g: 0.36, b: 0.88))
        },
        CarouselPage("input", caption: "Input — pointer, keyboard and accessibility") {
            CarouselCard("Input", detail: "Every control is reachable without a mouse.", tint: Color(r: 0.24, g: 0.66, b: 0.52))
        },
        CarouselPage("ship", caption: "Ship — one framework, many surfaces") {
            CarouselCard("Ship", detail: "Editor, runtime and in-game UI share the code.", tint: Color(r: 0.88, g: 0.52, b: 0.28))
        }
    ]}
}

private struct CarouselCard: View {
    let title: String
    let detail: String
    let tint: Color
    @State private var clicks = 0

    init(_ title: String, detail: String, tint: Color) {
        self.title = title; self.detail = detail; self.tint = tint
    }

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 6) {
            Text(title).font(.headline).foregroundColor(.white)
            Text(detail).font(.caption).foregroundColor(Color.white.multipliedAlpha(0.85))
            Button("Page action · \(clicks)") { clicks += 1 }.buttonStyle(.secondary)
        }
        .flex()
        .background(tint)
    }
}

struct ZStackStory: View {
    @State private var showsFront = true
    @State private var last = "none"

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Layered content", "Later children paint on top and receive pointer input first. The stack measures to its largest child; overflow stays painted unless the caller clips it.") {
                ZStack(alignment: .bottomTrailing) {
                    ZStack(alignment: .topLeading) {
                        Box {}.frame(width: 320, height: 180).background(.surfaceVariant).cornerRadius(12)
                        Box {}.frame(width: 150, height: 72).background(.accent).cornerRadius(10)
                            .overlay(alignment: .leading) {
                                Text("Top-left layer").font(.bodyStrong).foregroundColor(.onAccent)
                                    .padding(horizontal: 14)
                            }
                            .padding(14)
                    }
                    Badge("Overlay", tone: .success).padding(14)
                }.frame(width: 320, height: 180)
            }
            StorySection("Hit testing", "Click the overlapping buttons. The later child is on top; the earlier one remains reachable outside it.") {
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $showsFront)
                    Text("Show front layer").font(.caption)
                }
                ZStack {
                    Button("Back layer") { last = "back" }
                        .buttonStyle(.secondary).frame(width: 220, height: 72)
                    if showsFront {
                        Button("Front layer") { last = "front" }
                            .frame(width: 120, height: 44)
                    }
                }.frame(width: 220, height: 72)
                Text("Last activated: \(last)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
    }
}
