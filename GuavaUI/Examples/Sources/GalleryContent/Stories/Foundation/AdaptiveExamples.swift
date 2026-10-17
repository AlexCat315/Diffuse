import Foundation
import GuavaUI
import GuavaUIRuntime

/// Deterministic container and input previews, shared by the affected stories.
struct AdaptiveControlExamples: View {
    let page: GalleryPage
    let options: GalleryOptions
    static func supports(_ page: GalleryPage) -> Bool {
        switch page {
        case .button, .checkbox, .toggle, .slider, .textField, .numberField, .rating, .list, .calendar, .tabs, .buttonGroup, .stepper, .toolbar, .appBar, .form, .propertyGrid, .splitView, .sidebar, .navigationDrawer, .navigationRail, .table, .dataTable, .layout: true
        default: false
        }
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            preview("Narrow · pointer", width: 390, input: [.pointer, .keyboard])
            preview("Wide · pointer", width: 720, input: [.pointer, .keyboard])
            preview("Narrow · touch", width: 390, input: [.touch])
        }
    }
    private func preview(_ title: String, width: Float, input: UIEnvironment.Input) -> some View {
        var surface = UIEnvironment(); surface.viewport.width = width; surface.input = input
        let height: Float = page == .calendar ? 440 : page == .layout ? 280 : page == .table || page == .dataTable ? 260 : page == .navigationRail || page == .splitView || page == .sidebar ? 220 : page == .propertyGrid ? 200 : page == .form ? 180 : page == .tabs ? 160 : page == .list ? 144 : 104
        return StorySection(title, "The same component at an explicit surface width and input modality. Touch controls reserve at least 44 points; pointer hover remains available on pointer surfaces.") {
            ScrollView(.horizontal) {
                AdaptiveControlSample(page: page, options: options)
                    .frame(width: width, height: height).surfaceEnvironment(surface)
                    .debugName("adaptive-\(page.rawValue)-\(input.contains(.touch) ? "touch" : width < 600 ? "narrow" : "wide")")
            }.frame(height: height)
        }
    }
}

private struct AdaptiveControlSample: View {
    let page: GalleryPage
    let options: GalleryOptions
    @State private var text: TextBuffer = "Editable draft"
    @State private var number: Float = 1
    @State private var value: Double = 2.5
    @State private var enabled = true
    @State private var selected: Int? = 0
    @State private var tab = 0
    @State private var date: Date? = nil
    @State private var fraction: Float = 0.35
    @State private var navigationOpen = false
    var body: some View {
        Box(direction: .column, alignItems: .flexStart, justifyContent: .center, spacing: 12) {
            sample
        }.controlSize(options.size)
    }
    private var sample: AnyView {
        switch page {
        case .button: AnyView(Button("Save changes", isEnabled: options.isEnabled) { number += 1 })
        case .checkbox: AnyView(Checkbox(isOn: $enabled, isEnabled: options.isEnabled))
        case .toggle: AnyView(Toggle(isOn: $enabled, isEnabled: options.isEnabled))
        case .slider: AnyView(Slider(value: $value, range: 0...5, isEnabled: options.isEnabled).frame(width: .percent(100)))
        case .textField: AnyView(TextField("Name", text: $text) { $0.behavior.disabled = !options.isEnabled }.frame(width: .percent(100)))
        case .numberField: AnyView(NumberField(value: $number, isEnabled: options.isEnabled, showsStepper: true).frame(width: .percent(100)))
        case .rating: AnyView(Rating("Preview score", value: $value) { $0.selection.isEnabled = options.isEnabled; $0.selection.precision = .half })
        case .list: AnyView(List(0..<20, id: \.self, selection: $selected) { index, _ in Text("Item \(index + 1)") }.frame(width: .percent(100), height: .points(132)))
        case .table, .dataTable: AnyView(AdaptiveTableSample(data: page == .dataTable, options: options).frame(width: .percent(100), height: .percent(100)))
        case .layout: AnyView(GridColumnSample(options: options).frame(width: .percent(100)))
        case .calendar: AnyView(CalendarView(selection: $date) { $0.presentation.isEnabled = options.isEnabled })
        case .tabs: AnyView(TabView(selection: $tab, tabs: [
            TabItem("Overview", id: 0, isEnabled: options.isEnabled) { Text("Overview panel").padding(12) },
            TabItem("Details", id: 1, isEnabled: options.isEnabled) { Text("Details panel").padding(12) }
        ]) { $0.overflow = .scroll }.frame(width: .percent(100), height: .points(132)))
        case .buttonGroup: AnyView(ButtonGroup([ButtonGroupItem(0, "Grid"), ButtonGroupItem(1, "List")], selection: $selected, isEnabled: options.isEnabled))
        case .stepper: AnyView(Stepper([StepperItem(0, "Configure"), StepperItem(1, "Review")], selection: $selected) { $0.isEnabled = options.isEnabled }.frame(width: .percent(100)))
        case .toolbar: AnyView(Toolbar(items: [
            ToolbarItem(MenuItem(id: "save", title: "Save") { number += 1 }, placement: .always),
            ToolbarItem(MenuItem(id: "export", title: "Export selection") { text = "Exported" }, placement: .automatic(priority: 10)),
            ToolbarItem(MenuItem(id: "share", title: "Share project") { text = "Shared" }),
            ToolbarItem(MenuItem(id: "settings", title: "Project settings") { text = "Settings" })
        ], configure: { $0.isEnabled = options.isEnabled }).frame(width: .percent(100)))
        case .appBar: AnyView(AppBar("Workspace permissions and project access 👩🏽‍💻", subtitle: "Saved locally",
            back: MenuItem(id: "back", title: "Back") { text = "Back" },
            primary: ToolbarItem(MenuItem(id: "save", title: "Save") { number += 1 }, icon: .resource(UIIcons.Action.check)),
            actions: [
                ToolbarItem(MenuItem(id: "find", title: "Find") { text = "Find" }, icon: .resource(UIIcons.Action.search)),
                ToolbarItem(MenuItem(id: "export", title: "Export") { text = "Export" }, icon: .resource(UIIcons.Action.download)),
                ToolbarItem(MenuItem(id: "share", title: "Share") { text = "Share" }, icon: .resource(UIIcons.Action.share))
            ], configure: { $0.isEnabled = options.isEnabled }).frame(width: .percent(100)))
        case .form: AnyView(Form([
            FormField("adaptive-name", "Display name") { TextField("Name", text: $text) { $0.behavior.disabled = !options.isEnabled } }
        ]).frame(width: .percent(100)))
        case .propertyGrid: AnyView(PropertyGrid([
            PropertyGridSection(id: "preview", title: "Properties", rows: [
                PropertyGridRow(id: "name", label: "Display name") { TextField("Name", text: $text) { $0.behavior.disabled = !options.isEnabled } }
            ])
        ]).frame(width: .percent(100), height: .points(180)))
        case .splitView: AnyView(SplitView(.horizontal, fraction: $fraction,
            constraints: .init(minimumFirst: 150, minimumSecond: 220),
            compact: .init(firstTitle: "Navigation", secondTitle: "Details")) {
                Text("Navigation pane").padding(12).background(.surfaceVariant)
            } second: {
                TextField("Retained draft", text: $text) { $0.behavior.disabled = !options.isEnabled }.padding(12)
            }.frame(width: .percent(100), height: .points(210)))
        case .navigationDrawer: AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Button("Open navigation", isEnabled: options.isEnabled) { navigationOpen = true }
            NavigationDrawer("Preview workspace", isPresented: $navigationOpen, selection: $selected,
                sections: [SidebarSection("preview", items: [SidebarItem(0, "Overview"), SidebarItem(1, "Documents")])])
        })
        case .navigationRail: AnyView(NavigationRail(selection: $selected, items: [
            SidebarItem(0, "Overview") { $0.icon = UIIcons.Layout.dashboard; $0.isEnabled = options.isEnabled },
            SidebarItem(1, "Notifications") { $0.icon = UIIcons.Status.bell; $0.isEnabled = options.isEnabled }
        ]).frame(height: 210))
        case .sidebar: AnyView(AdaptiveSidebar("Preview workspace", isPresented: $navigationOpen, selection: $selected,
            sections: [SidebarSection("preview", items: [
                SidebarItem(0, "Overview") { $0.icon = UIIcons.Layout.dashboard; $0.isEnabled = options.isEnabled },
                SidebarItem(1, "Documents") { $0.icon = UIIcons.File.folder; $0.isEnabled = options.isEnabled }
            ])]) {
                TextField("Retained draft", text: $text) { $0.behavior.disabled = !options.isEnabled }.padding(12)
            }.frame(width: .percent(100), height: .points(210)))
        default: AnyView(EmptyView())
        }
    }
}
