import GuavaUI
import GuavaUIRuntime

struct BadgeStory: View {
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Status tones", "Semantic status labels inherit the active theme.") {
                Row(alignment: .center, spacing: 12) { for tone in StatusTone.allCases { Badge(String(describing: tone).capitalized, tone: tone) } }
            }
            StorySection("Variants", "Soft reads inside dense content, solid is a single callout, and outline sits beside a bordered surface.") {
                Row(alignment: .center, spacing: 12) {
                    Badge("Running") { $0.tone = .success; $0.variant = .soft }
                    Badge("Running") { $0.tone = .success; $0.variant = .solid }
                    Badge("Running") { $0.tone = .success; $0.variant = .outline }
                }
            }
            StorySection("Glyphs, dots and density", "The glyph carries the same meaning as the colour, so the tone survives a monochrome theme.") {
                Row(alignment: .center, spacing: 12) {
                    Badge("Passing") { $0.tone = .success; $0.icon = UIIcons.Status.checkCircle }
                    Badge("3 failures") { $0.tone = .danger; $0.showsDot = true }
                    Badge("Unverified") { $0.tone = .neutral; $0.isEnabled = false }
                }
                Row(alignment: .center, spacing: 8) {
                    Badge("Mini") { $0.tone = .info; $0.variant = .solid }.controlSize(.mini)
                    Badge("Small") { $0.tone = .info; $0.variant = .solid }.controlSize(.small)
                    Badge("Medium") { $0.tone = .info; $0.variant = .solid }.controlSize(.regular)
                    Badge("Large") { $0.tone = .info; $0.variant = .solid }.controlSize(.large)
                }
            }
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
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Progress & activity", "Determinate progress clamps to its range; the spinner stops when its owning node unmounts.") {
                ProgressView(value: progress)
                ProgressView(value: progress) { $0.tone = .success; $0.height = 8 }
                Slider(value: $progress, isEnabled: options.isEnabled)
                NumericText(progress * 100) { String(format: "%.0f%% complete", $0) }
                    .font(.caption).foregroundColor(.onSurfaceMuted)
                Row(alignment: .center, spacing: 12) { Spinner(); Text("Working…").font(.body); Button("Uploading…", isLoading: true) {} }
            }
            StorySection("Indeterminate", "Used when the total work is unknown — a fabricated percentage that never advances is worse than admitting the wait.") {
                ProgressView(value: nil)
                ProgressView(value: nil) { $0.tone = .warning }
                Row(alignment: .center, spacing: 16) {
                    ProgressCircle(value: progress, diameter: 44) { $0.showsValue = true }
                    ProgressCircle(value: progress, diameter: 28) { $0.tone = .success }
                    ProgressCircle(value: nil, diameter: 44) { $0.tone = .info }
                    ProgressCircle(value: 0.72, diameter: 56) { $0.showsValue = true; $0.tone = .warning }
                }
            }
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
        guard AdaptiveControlExamples.supports(self) else { return baseStory(options: options) }
        return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 24) {
            baseStory(options: options)
            AdaptiveControlExamples(page: self, options: options)
        })
    }

    private func baseStory(options: GalleryOptions) -> AnyView {
        switch self {
        case .introduction: AnyView(IntroductionStory(options: options))
        case .button: AnyView(ButtonStory(options: options))
        case .checkbox: AnyView(CheckboxStory(options: options))
        case .toggle: AnyView(ToggleStory(options: options))
        case .slider: AnyView(SliderStory(options: options))
        case .rangeSlider: AnyView(RangeSliderStory(options: options))
        case .rating: AnyView(RatingStory(options: options))
        case .textField: AnyView(TextFieldStory(options: options))
        case .searchField: AnyView(SearchFieldStory(options: options))
        case .textArea: AnyView(TextAreaStory(options: options))
        case .codeEditor: AnyView(CodeEditorStory(options: options))
        case .numberField: AnyView(NumberFieldStory(options: options))
        case .vec3Field: AnyView(Vec3Story(options: options))
        case .colorField: AnyView(ColorStory(options: options))
        case .select: AnyView(SelectStory(options: options))
        case .jsonField: AnyView(JsonStory(options: options))
        case .assetRef: AnyView(AssetStory(options: options))
        case .list: AnyView(ListStory())
        case .tree: AnyView(TreeStory(options: options))
        case .virtualList: AnyView(VirtualListStory())
        case .virtualStack: AnyView(VirtualStackStory())
        case .chart: AnyView(ChartStory())
        case .icon: AnyView(IconStory(options: options))
        case .avatar: AnyView(AvatarStory(options: options))
        case .image: AnyView(ImageStory(options: options))
        case .menu: AnyView(MenuStory(options: options))
        case .menuButton: AnyView(MenuButtonStory(options: options))
        case .contextMenu: AnyView(ContextMenuStory(options: options))
        case .popover: AnyView(PopoverStory(options: options))
        case .modal: AnyView(ModalStory(options: options))
        case .disclosure: AnyView(DisclosureStory(options: options))
        case .tabs: AnyView(TabsStory(options: options))
        case .panel: AnyView(PanelStory())
        case .splitView: AnyView(SplitStory())
        case .scrollView: AnyView(ScrollStory())
        case .boundedScroll: AnyView(BoundedScrollStory())
        case .propertyGrid: AnyView(PropertyGridStory(options: options))
        case .workspace: AnyView(WorkspaceStory())
        case .layout: AnyView(LayoutStory(options: options))
        case .zStack: AnyView(ZStackStory())
        case .animation: AnyView(AnimationStory(options: options))
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
        case .sidebar: AnyView(SidebarStory(options: options))
        case .navigationDrawer: AnyView(NavigationDrawerStory(options: options))
        case .navigationRail: AnyView(NavigationRailStory(options: options))
        case .appBar: AnyView(AppBarStory(options: options))
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
        case .bottomSheet: AnyView(BottomSheetStory(options: options))
        case .commandPalette: AnyView(CommandPaletteStory(options: options))
        case .hoverCard: AnyView(HoverCardStory(options: options))
        case .timeline: AnyView(TimelineStory())
        case .toolbar: AnyView(ToolbarStory(options: options))
        case .link: AnyView(LinkStory(options: options))
        case .statusBar: AnyView(StatusBarStory(options: options))
        case .carousel: AnyView(CarouselStory(options: options))
        case .skeleton: AnyView(SkeletonStory(options: options))
        case .stepper: AnyView(StepperStory(options: options))
        }
    }
}
