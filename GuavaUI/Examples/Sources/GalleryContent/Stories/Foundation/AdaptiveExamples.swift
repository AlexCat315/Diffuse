import Foundation
import GuavaUI
import GuavaUIRuntime
import GuavaUIWorkspace

/// Deterministic container and input previews, shared by the affected stories.
struct AdaptiveControlExamples: View {
    let page: GalleryPage
    let options: GalleryOptions
    static func supports(_ page: GalleryPage) -> Bool {
        switch page {
        case .button, .buttonGroup, .splitButton, .checkbox, .toggle, .slider, .rangeSlider, .textField, .searchField, .numberField, .vec3Field, .select, .combobox, .rating, .list, .sectionedList, .reorderableList, .swipeList, .refreshableList, .scrollbar, .calendar, .datePicker, .tabs, .stepper, .toolbar, .appBar, .navigationStack, .form, .propertyGrid, .splitView, .sidebar, .navigationDrawer, .navigationRail, .table, .dataTable, .layout, .masonry, .zStack, .viewportTraits, .viewThatFits, .dragAndDrop, .menuButton, .tooltip, .link, .badge, .tag, .keyCap, .progress, .empty, .skeleton, .accordion, .icon, .avatar, .panel, .scrollView, .statusBar, .carousel, .breadcrumb, .pagination, .radio, .timeline, .tree, .virtualStack, .chart, .boundedScroll, .label, .disclosure, .alert, .textArea, .colorField, .jsonField, .assetRef, .dateRangePicker, .timeField, .timePicker, .wheelPicker, .theme, .textEditor, .menu, .contextMenu, .popover, .popconfirm, .actionSheet, .modal, .dialog, .alertDialog, .sheet, .bottomSheet, .commandPalette, .hoverCard, .animation, .introduction, .image, .workspace, .notification: true
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
        let height: Float = page == .calendar ? 440 : page == .layout ? 280 : page == .masonry ? 190 : page == .zStack ? 120 : page == .table || page == .dataTable ? 260 : page == .navigationRail || page == .splitView || page == .sidebar ? 220 : page == .propertyGrid ? 200 : page == .form ? 180 : page == .tabs ? 160 : page == .list ? 144 : page == .sectionedList ? 160 : page == .reorderableList ? 180 : page == .swipeList ? 200 : page == .refreshableList ? 200 : page == .scrollbar ? 120 : page == .dragAndDrop ? 170 : page == .accordion ? 160 : page == .empty ? 140 : page == .skeleton ? 80 : page == .icon ? 80 : page == .avatar ? 100 : page == .panel ? 150 : page == .scrollView ? 120 : page == .statusBar ? 60 : page == .carousel ? 140 : page == .breadcrumb ? 80 : page == .pagination ? 80 : page == .radio ? 110 : page == .timeline ? 160 : page == .tree ? 160 : page == .virtualStack ? 130 : page == .chart ? 130 : page == .boundedScroll ? 160 : page == .label ? 140 : page == .disclosure ? 120 : page == .alert ? 140 : page == .textArea ? 160 : page == .colorField ? 150 : page == .jsonField ? 180 : page == .assetRef ? 120 : page == .theme ? 120 : page == .textEditor ? 150 : page == .wheelPicker ? 190 : page == .timePicker ? 190 : page == .popconfirm ? 150 : page == .workspace ? 220 : page == .image ? 120 : page == .introduction || page == .notification ? 100 : page == .animation ? 100 : page == .vec3Field ? 130 : page == .navigationStack ? 220 : 104
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
    @State private var reorderItems = Array(0..<6)
    @State private var swipeSelection: Int? = 1
    @State private var refreshPreview = false
    @State private var navigationPath: [String] = []
    @State private var navigationOpen = false
    @State private var scrollbarOffset: CGFloat = 0
    @State private var chartPoint: ChartPoint?
    @State private var dndLane: String?
    @State private var dndHover = false
    @State private var wheel: Int = 2
    @State private var pickerTime: TimeOfDay? = TimeOfDay(hour: 9, minute: 30)
    @State private var accordionExpanded: Set<Int> = [0]
    @State private var radioValue: Int? = 0
    @State private var paginationPage = 2
    @State private var carouselPage = 0
    @State private var treeSelection: String? = "camera"
    @State private var treeExpanded: Set<String> = ["scene", "lights"]
    @State private var treeSelectedIDs: Set<String> = ["camera"]
    @State private var disclosureOpen = true
    @State private var color = Color(red: 88, green: 126, blue: 231)
    @State private var json: TextBuffer = "{\"name\": \"Guava\"}"
    @State private var asset: AssetRef? = AssetRef(id: "camera", name: "Camera", kind: "image")
    @State private var time: TimeOfDay? = TimeOfDay(hour: 9, minute: 30)
    @State private var popoverOpen = false
    @State private var modalOpen = false
    @State private var dialogOpen = false
    @State private var alertDialogOpen = false
    @State private var sheetOpen = false
    @State private var bottomSheetOpen = false
    @State private var commandOpen = false
    @State private var animationVisible = true
    @State private var toast = ToastController()
    @State private var workspaceController = WorkspaceController(document: WorkspaceStory.defaultDocument())
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
        case .slider: AnyView(Row(alignment: .center, spacing: 16) {
            Slider(value: $value, range: 0...5, isEnabled: options.isEnabled).flex(1, shrink: 1)
            Slider(value: $value, range: 0...5, isEnabled: options.isEnabled, axis: .vertical).frame(height: 80)
        }.frame(width: .percent(100)))
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
        case .list: AnyView(List(0..<20, id: \.self, selection: $selected) { index, _ in
            ListRow("Item \(index + 1) — shared workspace settings and collaboration permissions") {
                Badge("Ready", tone: .success)
            }
        }.frame(width: .percent(100), height: .points(132)))
        case .sectionedList: AnyView(SectionedList([
            ListSection("preview-favorites", title: "Favorites",
                        items: Array(0..<4).map(AdaptiveSectionItem.init(id:))),
            ListSection("preview-scene", title: "Scene",
                        items: Array(4..<8).map(AdaptiveSectionItem.init(id:)))
        ], selection: $selected, stickyHeaders: true) { item, _ in
            ListRow(item.title + " — shared workspace settings and collaboration permissions") {
                Badge("Ready", tone: .success)
            }
        }.frame(width: .percent(100), height: .points(132)))
        case .reorderableList: AnyView(ReorderableList(
            reorderItems, id: \.self, rowHeight: 36, isEnabled: options.isEnabled,
            rowLabel: { "Item \($0 + 1)" },
            onMove: { from, to in
                guard reorderItems.indices.contains(from), (0..<reorderItems.count).contains(to) else { return }
                let moved = reorderItems.remove(at: from)
                reorderItems.insert(moved, at: to)
            }) { index, _ in
                Text("Item \(index + 1)")
            }.frame(width: .percent(100), height: .points(160)))
        case .swipeList: AnyView(SwipeList(0..<5, id: \.self, selection: $swipeSelection,
            rowHeight: 44, rowSpacing: 1, isEnabled: options.isEnabled,
            rowLabel: { "Row \($0 + 1)" },
            actions: { _ in
                [SwipeAction(title: "Archive") {},
                 SwipeAction(title: "Delete", tone: .danger) {}]
            }) { index, _ in
                Text("Row \(index + 1)")
            }.frame(width: .percent(100), height: .points(170)))
        case .refreshableList: AnyView(List(0..<6, id: \.self, selection: .constant(1),
            rowHeight: 44,
            refresh: RefreshOptions(isRefreshing: $refreshPreview, threshold: 64) {
                refreshPreview = true
            }) { index, _ in
                Text("Row \(index + 1)")
            }.frame(width: .percent(100), height: .points(170)))
        case .navigationStack: AnyView(NavigationStack(path: $navigationPath) {
            Column(alignment: .leading, spacing: 8) {
                Text("Root").font(.headline)
                Button("Open details") { navigationPath.append("details") }
            }
        } destination: { route in
            Column(alignment: .leading, spacing: 8) {
                Text(route.capitalized).font(.headline)
                Button("Back") { navigationPath.removeLast() }
            }
        }.frame(width: .percent(100), height: .points(170)))
        case .table, .dataTable: AnyView(AdaptiveTableSample(data: page == .dataTable, options: options).frame(width: .percent(100), height: .percent(100)))
        case .layout: AnyView(GridColumnSample(options: options).frame(width: .percent(100)))
        case .masonry: AnyView(MasonrySample().frame(width: .percent(100)))
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
        case .splitButton: AnyView(Box(direction: .column, alignItems: .stretch) {
            SplitButton("Run", entries: [.item(MenuItem(id: "export", title: "Export") { text = TextBuffer("Export") })], isEnabled: options.isEnabled) { text = TextBuffer("Run") }
        }.frame(width: .percent(100)))
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
        case .scrollbar: AnyView(Row(alignment: .center, spacing: 12) {
            Scrollbar(offset: $scrollbarOffset, contentExtent: 800, viewportExtent: 100)
                .frame(width: 12, height: 100)
            Text("Offset \(Int(scrollbarOffset))").font(.caption)
        })
        case .viewportTraits: AnyView(Column(alignment: .leading, spacing: 4) {
            ViewportTraitLabels()
        })
        case .viewThatFits: AnyView(ViewThatFits(fitting: .intrinsic) {
            Row(spacing: 8) { Text("Wide"); Text("Files"); Text("Preview"); Text("Settings") }
        } compact: {
            Column(spacing: 4) { Text("Compact"); Text("Files"); Text("Preview"); Text("Settings") }
        }.frame(width: .percent(100), height: .points(100)))
        case .dragAndDrop: AnyView(DragScope {
            Column(alignment: .leading, spacing: 8) {
                Draggable("Camera", preview: { Text("Camera").font(.caption).padding(6).background(.surfaceVariant) }) {
                    Text("Camera").font(.caption).padding(horizontal: 10, vertical: 6).background(.surfaceRaised).cornerRadius(6)
                }
                DropTarget(onTargeted: { dndHover = $0 }, onDrop: { dndLane = $0 }) {
                    Text(dndLane ?? "Drop here").font(.caption)
                        .frame(width: 120, height: 44)
                        .background(dndHover ? .selection : .surfaceSunken).cornerRadius(8)
                }
            }
        }.frame(height: 160))
        case .menuButton: AnyView(MenuButton("Actions", entries: [
            .item(MenuItem(id: "duplicate", title: "Duplicate") {}),
            .item(MenuItem(id: "delete", title: "Delete", role: .destructive) {})
        ], isEnabled: options.isEnabled))
        case .tooltip: AnyView(Text("Hover for details").tooltip("Full tooltip description").padding(8))
        case .link: AnyView(Link("Open documentation") {})
        case .badge: AnyView(Badge("Beta") { $0.tone = .info })
        case .tag: AnyView(Tag("Design") { $0.tone = .info })
        case .keyCap: AnyView(KeyCap(["⌘", "K"]))
        case .progress: AnyView(ProgressView(value: 0.6).frame(width: .percent(100)))
        case .empty: AnyView(EmptyState("No results", message: "Try another search") {})
        case .skeleton: AnyView(Skeleton {
            $0.appearance.height = 20
            $0.appearance.shape = .rectangle(cornerRadius: 4)
        }.frame(width: .percent(100)))
        case .accordion: AnyView(Accordion([
            AccordionItem(0, "Details") { Text("Accordion content") }
        ], expanded: $accordionExpanded).frame(width: .percent(100), height: .points(120)))
        case .popconfirm: AnyView(Popconfirm("Preview deletion", title: "Delete this item?", message: "This cannot be undone.", confirmTitle: "Delete", role: .destructive, isEnabled: options.isEnabled) {})
        case .actionSheet: AnyView(ActionSheetPreview(isEnabled: options.isEnabled))
        case .timePicker: AnyView(Box(direction: .row, alignItems: .center, justifyContent: .center) {
            TimePicker(selection: $pickerTime) { $0.minuteStep = 5; $0.isEnabled = options.isEnabled }
                .frame(width: 320)
        }.frame(width: .percent(100)))
        case .wheelPicker: AnyView(Box(direction: .row, alignItems: .center, justifyContent: .center) {
            WheelPicker(selection: $wheel, options: (0...4).map { WheelPickerOption($0, "Row \($0 + 1)") }, isEnabled: options.isEnabled, visibleRows: 3, label: "Preview wheel")
                .frame(width: 240)
        }.frame(width: .percent(100)))
        case .datePicker: AnyView(DatePicker(selection: $date) {
            $0.presentation.width = 240
            $0.presentation.isEnabled = options.isEnabled
        })
        case .icon: AnyView(Icon(UIIcons.Action.check, size: 24))
        case .avatar: AnyView(Avatar("Alex Morgan"))
        case .panel: AnyView(Panel("Inspector", accessory: {
            Icon(UIIcons.Action.moreHorizontal, size: .small)
        }, content: {
            Text("Panel content").padding(12)
        }).frame(width: .percent(100), height: .points(130)))
        case .scrollView: AnyView(ScrollView(.vertical) {
            Column(alignment: .leading, spacing: 8) {
                Text("Scrollable content").font(.caption)
                Text("Second line").font(.caption)
            }.padding(12)
        }.frame(width: .percent(100), height: .points(100)))
        case .statusBar: AnyView(StatusBar {
            StatusBarText("Ready", detail: "3 items")
        } trailing: {
            StatusBarText("Ln 1", detail: "Col 4")
        }.frame(width: .percent(100)))
        case .carousel: AnyView(Carousel(pages: [
            CarouselPage(0) { Text("Page 1").frame(height: 90) },
            CarouselPage(1) { Text("Page 2").frame(height: 90) }
        ], selection: $carouselPage).frame(height: 130))
        case .breadcrumb: AnyView(Breadcrumb([
            BreadcrumbItem(0, "Workspace"), BreadcrumbItem(1, "Assets"), BreadcrumbItem(2, "Camera")
        ], onSelect: { _ in }).frame(width: .percent(100)))
        case .pagination: AnyView(Pagination(page: $paginationPage, totalPages: 8).frame(width: .percent(100)))
        case .radio: AnyView(RadioGroup(selection: $radioValue, options: [
            RadioOption(0, "Option one"), RadioOption(1, "Option two")
        ]) { $0.isEnabled = options.isEnabled })
        case .timeline: AnyView(ScrollView(.vertical) {
            Timeline(events: [
                TimelineEvent("Created", detail: "Workspace", trailing: "09:12", tone: .success),
                TimelineEvent("Updated international collaboration permissions 👩🏽‍💻", detail: "All workspace profiles are available.",
                              trailing: "10:04 · Shanghai", tone: .info)
            ])
        }.frame(width: .percent(100), height: .points(140)))
        case .tree: AnyView(Tree(galleryTree, id: \.id, children: { $0.children },
            hasChildren: { !$0.children.isEmpty }, configure: { tree in
                tree.isEnabled = options.isEnabled
                tree.selection.primary = $treeSelection
                tree.selection.multiple = $treeSelectedIDs
                tree.selection.expanded = $treeExpanded
                tree.search.text = { $0.title }
            }) { node, _, _, _ in
                Text(node.title).font(.body)
            }.frame(width: .percent(100), height: .points(140)))
        case .virtualStack: AnyView(VirtualStack(Array(0..<300), id: \.self, rowHeight: 28) { row in
            Text("Record \(row + 1)").padding(horizontal: 8)
        }.frame(width: .percent(100), height: .points(110)))
        case .chart: AnyView(Chart([.bar([12, 19, 16, 28, 21, 35], title: "Orders")]) { $0.selection.point = $chartPoint }.frame(width: .percent(100), height: .points(110)))
        case .boundedScroll: AnyView(BoundedScrollView(contentHeight: 240, minHeight: 90, maxHeight: 150) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                for row in 0..<8 {
                    AnyView(Text("Row \(row + 1)").font(.caption).frame(height: 30))
                }
            }
        }.frame(width: .percent(100)))
        case .label: AnyView(Form([
            FormField("adaptive-label", "Display name", configure: { $0.isRequired = true; $0.help = "Visible to teammates" }) {
                TextField("Name", text: $text) { $0.behavior.disabled = !options.isEnabled }
            }
        ]).frame(width: .percent(100)))
        case .disclosure: AnyView(DisclosureGroup("Project details", isExpanded: $disclosureOpen,
            isEnabled: options.isEnabled) {
            Text("Collapsible content").padding(8)
        }.frame(width: .percent(100)))
        case .alert: AnyView(Alert("Project saved", message: "All changes are available.", tone: .success)
            .frame(width: .percent(100)))
        case .textArea: AnyView(ResizableTextArea("Write a note…", text: $text, minHeight: 80,
            maxHeight: 150, disabled: !options.isEnabled).frame(width: .percent(100)))
        case .colorField: AnyView(ColorField(color: $color, isEnabled: options.isEnabled,
            showsInlineValues: true).frame(width: .percent(100)))
        case .jsonField: AnyView(JsonField(text: $json, minHeight: 90, isEnabled: options.isEnabled)
            .frame(width: .percent(100)))
        case .assetRef: AnyView(AssetRefField(value: $asset, acceptedKinds: ["image"],
            pickerOptions: [AssetRef(id: "light", name: "Key Light", kind: "image")],
            placeholder: "Drop image", isEnabled: options.isEnabled).frame(width: .percent(100)))
        case .dateRangePicker: AnyView(DateRangePicker(selection: $dateRange) {
            $0.presentation.width = 260
            $0.presentation.isEnabled = options.isEnabled
        })
        case .timeField: AnyView(TimeField(value: $time) {
            $0.isEnabled = options.isEnabled
            $0.minuteStep = 5
        }.frame(width: 200))
        case .theme: AnyView(ThemeReader { theme in
            Row(spacing: 10) {
                Text("Accent").foregroundColor(.accent)
                Text("Surface").padding(6).background(theme.colors.surfaceRaised)
                Text("Muted").foregroundColor(.onSurfaceMuted)
            }
        }.frame(width: .percent(100)))
        case .textEditor: AnyView(TextField("", text: $text) { input in
            input.layout.axis = .vertical
            input.layout.wrapsLines = true
            input.layout.maxVisibleLines = 6
            input.behavior.disabled = !options.isEnabled
        }.frame(width: .percent(100), height: .points(110)))
        case .menu: AnyView(MenuButton("Menu", entries: [
            .item(MenuItem(id: "rename", title: "Rename") {}),
            .item(MenuItem(id: "delete", title: "Delete", role: .destructive) {})
        ], isEnabled: options.isEnabled))
        case .contextMenu: AnyView(ContextMenu(entries: {
            [.item(MenuItem(id: "inspect", title: "Inspect") {})]
        }) {
            Text("Right-click for menu").font(.caption)
                .padding(horizontal: 12, vertical: 8)
                .background(.surfaceVariant).cornerRadius(6)
        })
        case .popover: AnyView(Column(alignment: .leading, spacing: 8) {
            Popover(isPresented: $popoverOpen, width: 200, label: {
                Text("Open popover").padding(8)
            }, content: {
                Text("Popover content")
            })
        })
        case .modal: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Open modal") { modalOpen = true }
            Modal(isPresented: $modalOpen) {
                Box(direction: .column, alignItems: .stretch) {
                    Text("Modal content").padding(16)
                    Button("Close") { modalOpen = false }.buttonStyle(.secondary).padding(16)
                }.frame(width: 260, height: 180)
            }
        })
        case .dialog: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Open dialog") { dialogOpen = true }
            Dialog(isPresented: $dialogOpen, title: "Edit profile") {
                Text("Dialog content").padding(12)
            } footer: {
                Button("Close") { dialogOpen = false }
            }
        })
        case .alertDialog: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Delete") { alertDialogOpen = true }.buttonStyle(.destructive)
            AlertDialog(isPresented: $alertDialogOpen, title: "Delete?",
                        message: "This cannot be undone.", onConfirm: {})
        })
        case .sheet: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Open sheet") { sheetOpen = true }
            Sheet(isPresented: $sheetOpen, configure: { $0.edge = .trailing; $0.extent = 260 }) {
                Text("Sheet content").padding(16)
            }
        })
        case .bottomSheet: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Open bottom sheet") { bottomSheetOpen = true }
            BottomSheet(isPresented: $bottomSheetOpen) {
                Text("Bottom sheet content").padding(16)
            }
        })
        case .commandPalette: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Open commands") { commandOpen = true }
            CommandPalette(isPresented: $commandOpen, items: [
                CommandItem("Save") {},
                CommandItem("Open settings", group: "Workspace") {}
            ])
        })
        case .hoverCard: AnyView(HoverCard(width: 220, label: {
            Text("Hover target").font(.caption).padding(8).background(.surfaceVariant).cornerRadius(6)
        }, content: {
            Text("Hover card detail").padding(12)
        }))
        case .animation: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Toggle animation") { animationVisible.toggle() }
            AnimatedVisibility(isVisible: animationVisible) {
                Text("Animated content").font(.caption).padding(8)
            }
        })
        case .introduction: AnyView(Column(alignment: .leading, spacing: 6) {
            Text("GuavaUI").font(.title)
            Text("Component showcase").font(.body).foregroundColor(.onSurfaceMuted)
        }.frame(width: .percent(100)))
        case .image: AnyView(AsyncImage(url: ImageStory.resource.url, width: 180, height: 90,
            contentMode: .fit) { phase in
            switch phase {
            case .success(let image):
                image
            case .failure:
                Text("Image unavailable").font(.caption)
            default:
                Text("Loading image…").font(.caption)
            }
        }.frame(width: 180, height: 90))
        case .notification: AnyView(Column(alignment: .leading, spacing: 8) {
            Button("Notify") {
                toast.post(ToastNotification("Project saved") { $0.tone = .success })
            }
            NotificationHost(toast)
        })
        case .workspace: AnyView(WorkspaceView(controller: workspaceController) { id in
            AnyView(Text(id.rawValue.capitalized).padding(8))
        }.frame(width: .percent(100), height: .points(190)))
        default: AnyView(EmptyView())
        }
    }

    private var selectionOptions: [SelectOption<Int>] {
        [SelectOption(value: 0, label: "Workspace permissions and international collaboration 👩🏽‍💻"),
         SelectOption(value: 1, label: "Personal workspace"),
         SelectOption(value: 2, label: "Unavailable", isEnabled: false)]
    }
}

struct ViewportTraitsStory: View {
    var body: some View {
        SurfaceReader { surface in
            StorySection("Viewport traits", "Width and height classes use independent 600/1000pt thresholds. Orientation is portrait below square and landscape at or above it; readers recompose when the surface changes without remounting their content.") {
                WidthClassReader { width in
                    HeightClassReader { height in
                        OrientationReader { orientation in
                            Column(alignment: .leading, spacing: 10) {
                                Text("Viewport: \(Int(surface.viewport.width)) × \(Int(surface.viewport.height))")
                                    .font(.caption).foregroundColor(.onSurfaceMuted)
                                    .debugName("viewport-size")
                                Text("Width class: \(Self.name(width))")
                                    .font(.body).debugName("viewport-width-class")
                                Text("Height class: \(Self.name(height))")
                                    .font(.body).debugName("viewport-height-class")
                                Text("Orientation: \(Self.name(orientation))")
                                    .font(.body).debugName("viewport-orientation")
                                Text("Compact < 600 · Medium 600–999 · Expanded ≥ 1000")
                                    .font(.caption).foregroundColor(.onSurfaceMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func name(_ width: UIEnvironment.WidthClass) -> String {
        switch width {
        case .compact: "compact"
        case .medium: "medium"
        case .expanded: "expanded"
        }
    }

    private static func name(_ height: UIEnvironment.HeightClass) -> String {
        switch height {
        case .compact: "compact"
        case .medium: "medium"
        case .expanded: "expanded"
        }
    }

    private static func name(_ orientation: UIEnvironment.Orientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .landscape: "landscape"
        }
    }
}

struct ViewThatFitsStory: View {
    @State private var narrow = false

    var body: some View {
        StorySection("Intrinsic fitting", "The wide branch is measured at an unspecified width. It stays selected while its natural width and height fit; otherwise the compact branch replaces it while both subtrees retain their state.") {
            Button(narrow ? "Use wide proposal" : "Use narrow proposal") { narrow.toggle() }
                .buttonStyle(.secondary)
            ViewThatFits(fitting: .intrinsic) {
                Row(spacing: 8) {
                    Text("Intrinsic wide").font(.caption)
                    chip("Files")
                    chip("Preview")
                    chip("Settings")
                }
            } compact: {
                Column(spacing: 8) {
                    Text("Intrinsic compact").font(.caption)
                    chip("Files")
                    chip("Preview")
                    chip("Settings")
                }
            }
            .frame(width: narrow ? 180 : 520)
            .debugName("intrinsic-fit")
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title).font(.caption)
            .padding(horizontal: 10, vertical: 6)
            .background(.surfaceVariant).cornerRadius(6)
    }
}


private struct ViewportTraitLabels: View {
    var body: some View {
        WidthClassReader { width in
            HeightClassReader { height in
                OrientationReader { orientation in
                    Column(alignment: .leading, spacing: 4) {
                        Text("Width: \(width)").font(.caption)
                        Text("Height: \(height)").font(.caption)
                        Text("Orientation: \(orientation)").font(.caption)
                    }
                }
            }
        }
    }
}
