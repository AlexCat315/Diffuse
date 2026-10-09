import GuavaUICompose
import GuavaUIRuntime

struct IntroductionStory: View {
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Explore the catalog", "Choose a component in the sidebar or search by name, category or behavior.") {
                Text("GuavaUI component showcase").font(.title)
                Text("Each page renders the real component. Change density, disable controls, switch theme or reset the example.").font(.body).foregroundColor(.onSurfaceVariant)
                Row(alignment: .center, spacing: 12) { Badge("\(GalleryCatalog.entries.count) stories", tone: .info); Badge("Light + dark", tone: .success); Badge("Keyboard + pointer", tone: .neutral) }
            }
            Alert("Scope of this catalog", message: "GuavaUI focuses on engine and editor interfaces. Rich text, diff editing and advanced charts are still areas of work; each component page shows its current capabilities.", tone: .info)
        }
    }
}

struct BadgeStory: View {
    var body: some View {
        StorySection("Status tones", "Semantic status labels inherit the active theme.") {
            Row(alignment: .center, spacing: 12) { for tone in StatusTone.allCases { Badge(String(describing: tone).capitalized, tone: tone) } }
        }
    }
}

struct AlertStory: View {
    var body: some View {
        StorySection("Inline feedback", "State the result and explain what the user can do next.") {
            Alert("Project saved", message: "All changes are available in the workspace.", tone: .success)
            Alert("Connection interrupted", message: "Retry when the connection is available.", tone: .warning)
            Alert("Import failed", message: "The selected asset format is unsupported.", tone: .danger)
            Alert("Update available", message: "Restart to use the new version.", tone: .info)
        }
    }
}

struct ProgressStory: View {
    let options: GalleryOptions
    @State private var progress = 0.45
    var body: some View {
        StorySection("Progress & activity", "Determinate progress clamps to its range; the spinner stops when its owning node unmounts.") {
            ProgressView(value: progress)
            Slider(value: $progress, isEnabled: options.isEnabled)
            Text("\(Int(progress * 100))% complete").font(.caption).foregroundColor(.onSurfaceMuted)
            Row(alignment: .center, spacing: 12) { Spinner(); Text("Working…").font(.body); Button("Uploading…", isLoading: true) {} }
        }
    }
}

struct EmptyStory: View {
    @State private var created = false
    var body: some View {
        StorySection("Empty content", "A recovery action turns an empty page into a useful starting point.") {
            if created { Alert("Your first project is ready", message: "Reset the example to restore the empty state.", tone: .success) }
            else { EmptyState("No projects yet", message: "Create a project to get started.") { Button("Create project") { created = true } } }
        }
    }
}

struct SliderStory: View {
    let options: GalleryOptions
    @State private var continuous = 0.6
    @State private var stepped = 3.0
    @State private var editing = false
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Continuous", "Pointer capture preserves dragging outside the track. Arrows, Home and End work with keyboard focus.") {
                Slider(value: $continuous, isEnabled: options.isEnabled, onEditingChanged: { editing = $0 })
                Text("Value: \(continuous)  ·  \(editing ? "Dragging" : "Idle")").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Stepped & disabled", "Steps are relative to the lower bound and clamp at the range edges.") {
                Slider(value: $stepped, range: 0...5, step: 1, isEnabled: options.isEnabled)
                Slider(value: .constant(0.4), isEnabled: false)
                Text("Step: \(Int(stepped))").font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
    }
}

public extension GalleryPage {
    func makeStory(options: GalleryOptions = GalleryOptions()) -> AnyView {
        switch self {
        case .introduction: AnyView(IntroductionStory())
        case .button: AnyView(ButtonStory(options: options))
        case .checkbox: AnyView(CheckboxStory(options: options))
        case .toggle: AnyView(ToggleStory(options: options))
        case .slider: AnyView(SliderStory(options: options))
        case .rating: AnyView(RatingStory(options: options))
        case .textField: AnyView(TextFieldStory(options: options))
        case .textArea: AnyView(TextAreaStory(options: options))
        case .codeEditor: AnyView(CodeEditorStory(options: options))
        case .numberField: AnyView(NumberFieldStory(options: options))
        case .vec3Field: AnyView(Vec3Story(options: options))
        case .colorField: AnyView(ColorStory(options: options))
        case .select: AnyView(SelectStory(options: options))
        case .jsonField: AnyView(JsonStory(options: options))
        case .assetRef: AnyView(AssetStory(options: options))
        case .list: AnyView(ListStory())
        case .tree: AnyView(TreeStory())
        case .virtualList: AnyView(VirtualListStory())
        case .virtualStack: AnyView(VirtualStackStory())
        case .chart: AnyView(ChartStory())
        case .icon: AnyView(IconStory())
        case .avatar: AnyView(AvatarStory(options: options))
        case .image: AnyView(ImageStory(options: options))
        case .menu: AnyView(MenuStory(options: options))
        case .contextMenu: AnyView(ContextMenuStory(options: options))
        case .popover: AnyView(PopoverStory(options: options))
        case .modal: AnyView(ModalStory(options: options))
        case .disclosure: AnyView(DisclosureStory(options: options))
        case .tabs: AnyView(TabsStory())
        case .panel: AnyView(PanelStory())
        case .splitView: AnyView(SplitStory())
        case .scrollView: AnyView(ScrollStory())
        case .boundedScroll: AnyView(BoundedScrollStory())
        case .propertyGrid: AnyView(PropertyGridStory(options: options))
        case .workspace: AnyView(WorkspaceStory())
        case .layout: AnyView(LayoutStory())
        case .animation: AnyView(AnimationStory())
        case .theme: AnyView(ThemeStory())
        case .badge: AnyView(BadgeStory())
        case .alert: AnyView(AlertStory())
        case .progress: AnyView(ProgressStory(options: options))
        case .empty: AnyView(EmptyStory())
        case .radio: AnyView(RadioStory(options: options))
        case .form: AnyView(FormStory(options: options))
        case .combobox: AnyView(ComboboxStory(options: options))
        case .notification: AnyView(NotificationStory())
        case .tooltip: AnyView(TooltipStory())
        case .sidebar: AnyView(SidebarStory())
        case .table: AnyView(TableStory(options: options))
        case .dataTable: AnyView(DataTableStory(options: options))
        case .calendar: AnyView(CalendarStory(options: options))
        case .datePicker: AnyView(DatePickerStory(options: options))
        case .timeField: AnyView(TimeFieldStory(options: options))
        case .accordion: AnyView(AccordionStory(options: options))
        case .breadcrumb: AnyView(BreadcrumbStory())
        case .pagination: AnyView(PaginationStory(options: options))
        case .buttonGroup: AnyView(ButtonGroupStory(options: options))
        case .tag: AnyView(TagStory(options: options))
        case .keyCap: AnyView(KeyCapStory())
        case .label: AnyView(LabelStory())
        case .dialog: AnyView(DialogStory())
        case .alertDialog: AnyView(AlertDialogStory())
        case .sheet: AnyView(SheetStory(options: options))
        }
    }
}
