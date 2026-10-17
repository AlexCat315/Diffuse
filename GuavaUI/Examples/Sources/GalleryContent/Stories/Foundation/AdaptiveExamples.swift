import Foundation
import GuavaUI
import GuavaUIRuntime

/// Deterministic container and input previews, shared by the affected stories.
struct AdaptiveControlExamples: View {
    let page: GalleryPage
    let options: GalleryOptions
    static func supports(_ page: GalleryPage) -> Bool {
        switch page {
        case .button, .buttonGroup, .splitButton, .checkbox, .toggle, .slider, .rangeSlider, .textField, .searchField, .numberField, .vec3Field, .select, .combobox, .rating, .list, .sectionedList, .calendar, .tabs, .stepper, .toolbar, .appBar, .form, .propertyGrid, .splitView, .sidebar, .navigationDrawer, .navigationRail, .table, .dataTable, .layout, .zStack: true
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
        let height: Float = page == .calendar ? 440 : page == .layout ? 280 : page == .zStack ? 120 : page == .table || page == .dataTable ? 260 : page == .navigationRail || page == .splitView || page == .sidebar ? 220 : page == .propertyGrid ? 200 : page == .form ? 180 : page == .tabs ? 160 : page == .list ? 144 : page == .sectionedList ? 160 : page == .vec3Field ? 130 : 104
        return StorySection(title, "The same component at an explicit surface width and input modality. Touch controls reserve at least 44 points; pointer hover remains available on pointer surfaces.") {
            ScrollView(.horizontal) {
                AdaptiveControlSample(page: page, options: options)
                    .frame(width: width, height: height).surfaceEnvironment(surface)
                    .debugName("adaptive-\(page.rawValue)-\(input.contains(.touch) ? "touch" : width < 600 ? "narrow" : "wide")")
            }.frame(height: height)
        }
    }
}

private struct AdaptiveSectionItem: Identifiable {
    let id: Int
    var title: String { "Item \(id + 1)" }
}

private struct AdaptiveControlSample: View {
    let page: GalleryPage
    let options: GalleryOptions
    @State private var text: TextBuffer = "Editable draft"
    @State private var number: Float = 1
    @State private var vecX: Float = 1.5
    @State private var vecY: Float = -2
    @State private var vecZ: Float = 3.25
    @State private var value: Double = 2.5
    @State private var enabled = true
    @State private var selected: Int? = 0
    @State private var tab = 0
    @State private var date: Date? = nil
    @State private var dateRange: ClosedRange<Date>? = nil
    @State private var fraction: Float = 0.35
    @State private var range: ClosedRange<Double> = 20...80
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
        case .rangeSlider: AnyView(RangeSlider(values: $range, in: 0...100, step: 1, minimumSpan: 5, isEnabled: options.isEnabled).frame(width: .percent(100)))
        case .textField: AnyView(TextField("Name", text: $text) { $0.behavior.disabled = !options.isEnabled }.frame(width: .percent(100)))
        case .searchField: AnyView(SearchField(text: $text, suggestions: ["Camera", "Canvas"], isEnabled: options.isEnabled).frame(width: .percent(100)))
        case .numberField: AnyView(NumberField(value: $number, isEnabled: options.isEnabled, showsStepper: true).frame(width: .percent(100)))
        case .vec3Field: AnyView(Vec3Field(
            x: Binding(get: { vecX }, set: { vecX = $0 }),
            y: Binding(get: { vecY }, set: { vecY = $0 }),
            z: Binding(get: { vecZ }, set: { vecZ = $0 }),
            isEnabled: options.isEnabled, step: 0.1).frame(width: .points(220)))
        case .select: AnyView(Select(selection: Binding(get: { selected ?? -1 }, set: { selected = $0 }), options: selectionOptions,
            isEnabled: options.isEnabled).frame(width: .percent(100)))
        case .combobox: AnyView(Combobox(selection: $selected, options: selectionOptions) {
            $0.isEnabled = options.isEnabled
        }.frame(width: .percent(100)))
        case .rating: AnyView(Rating("Preview score", value: $value) { $0.selection.isEnabled = options.isEnabled; $0.selection.precision = .half })
        case .list: AnyView(List(0..<20, id: \.self, selection: $selected) { index, _ in Text("Item \(index + 1)") }.frame(width: .percent(100), height: .points(132)))
        case .sectionedList: AnyView(SectionedList([
            ListSection("preview-favorites", title: "Favorites",
                        items: Array(0..<4).map(AdaptiveSectionItem.init(id:))),
            ListSection("preview-scene", title: "Scene",
                        items: Array(4..<8).map(AdaptiveSectionItem.init(id:)))
        ], selection: $selected, stickyHeaders: true) { item, _ in
            Text(item.title)
        }.frame(width: .percent(100), height: .points(132)))
        case .table, .dataTable: AnyView(AdaptiveTableSample(data: page == .dataTable, options: options).frame(width: .percent(100), height: .percent(100)))
        case .layout: AnyView(GridColumnSample(options: options).frame(width: .percent(100)))
        case .zStack: AnyView(ZStack {
            Box {}.frame(width: .percent(100), height: .percent(100))
                .background(.surfaceVariant).cornerRadius(8)
            Text("Layered content").font(.bodyStrong)
        }.frame(width: .percent(100), height: .points(80)))
        case .calendar: AnyView(CalendarView(selection: $date) { $0.presentation.isEnabled = options.isEnabled })
        case .tabs: AnyView(TabView(selection: $tab, tabs: [
            TabItem("Overview", id: 0, isEnabled: options.isEnabled) { Text("Overview panel").padding(12) },
            TabItem("Details", id: 1, isEnabled: options.isEnabled) { Text("Details panel").padding(12) },
            TabItem("Workspace permissions and collaboration", id: 2, isEnabled: options.isEnabled) { Text("Permissions panel").padding(12) },
            TabItem("Unavailable", id: 3, isEnabled: false) { EmptyView() }
        ]) { $0.overflow = .menu; $0.isEnabled = options.isEnabled }.frame(width: .percent(100), height: .points(132)))
        case .buttonGroup: AnyView(ButtonGroup([
            ButtonGroupItem(0, "Grid view"), ButtonGroupItem(1, "List view"),
            ButtonGroupItem(2, "Timeline"), ButtonGroupItem(3, "Inspector"),
            ButtonGroupItem(4, "Materials")
        ], selection: $selected, isEnabled: options.isEnabled))
        case .splitButton: AnyView(SplitButton("Run", entries: [.item(MenuItem(id: "export", title: "Export") { text = TextBuffer("Export") })], isEnabled: options.isEnabled) { text = TextBuffer("Run") })
        case .stepper: AnyView(Stepper([
            StepperItem(0, "Configure") { $0.detail = "Workspace"; $0.status = .completed },
            StepperItem(1, "Review") { $0.detail = "Permissions" },
            StepperItem(2, "Publish") { $0.detail = "Release" }
        ], selection: $selected) { $0.isEnabled = options.isEnabled }.frame(width: .percent(100)))
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

    private var selectionOptions: [SelectOption<Int>] {
        [SelectOption(value: 0, label: "Workspace permissions and international collaboration 👩🏽‍💻"),
         SelectOption(value: 1, label: "Personal workspace"),
         SelectOption(value: 2, label: "Unavailable", isEnabled: false)]
    }
}
