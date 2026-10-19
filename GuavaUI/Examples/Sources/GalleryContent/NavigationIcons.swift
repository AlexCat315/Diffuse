import GuavaUI
import GuavaUIRuntime

extension GalleryPage {
    /// One icon per page, so neighbouring sidebar rows stay distinguishable;
    /// only true families (dates, times) share a glyph.
    var navigationIcon: BundleImageResource {
        switch self {
        case .introduction: UIIcons.Layout.dashboard
        case .button: UIIcons.Action.target
        case .buttonGroup: UIIcons.Text.alignCenter
        case .splitButton: UIIcons.Navigation.cornerDownRight
        case .checkbox: UIIcons.Shape.squareCheck
        case .toggle: UIIcons.Action.power
        case .slider: UIIcons.Action.sliders
        case .rangeSlider: UIIcons.Navigation.expand
        case .numberField: UIIcons.Shape.hash
        case .vec3Field: UIIcons.Editor.box
        case .rating: UIIcons.Status.star
        case .textField: UIIcons.Text.type
        case .textArea: UIIcons.Text.alignLeft
        case .textEditor: UIIcons.Editor.terminal
        case .label: UIIcons.Text.heading
        case .searchField: UIIcons.Action.search
        case .jsonField: UIIcons.Editor.brackets
        case .colorField: UIIcons.Editor.brush
        case .theme: UIIcons.Device.moon
        case .select: UIIcons.Navigation.chevronsUpDown
        case .combobox: UIIcons.Action.filter
        case .assetRef: UIIcons.Shape.paperclip
        case .list: UIIcons.Text.list
        case .sectionedList: UIIcons.Text.listOrdered
        case .virtualStack: UIIcons.Device.database
        case .reorderableList: UIIcons.Action.grip
        case .swipeList: UIIcons.Navigation.chevronsLeft
        case .refreshableList: UIIcons.Navigation.refresh
        case .scrollbar: UIIcons.Layout.rows3
        case .viewportTraits: UIIcons.Navigation.maximize
        case .viewThatFits: UIIcons.Navigation.shrink
        case .dragAndDrop: UIIcons.Navigation.arrowDownRight
        case .tree: UIIcons.Editor.gitBranch
        case .chart: UIIcons.Data.chartLine
        case .icon: UIIcons.Status.sparkles
        case .image: UIIcons.Media.image
        case .carousel: UIIcons.Editor.skipForward
        case .web: UIIcons.Shape.globe
        case .avatar: UIIcons.User.user
        case .menu: UIIcons.Action.moreHorizontal
        case .menuButton: UIIcons.Action.moreVertical
        case .contextMenu: UIIcons.Navigation.moveRight
        case .commandPalette: UIIcons.Status.zap
        case .navigationStack: UIIcons.Navigation.arrowLeft
        case .popover: UIIcons.Shape.messageSquare
        case .popconfirm: UIIcons.Status.help
        case .tooltip: UIIcons.Status.info
        case .hoverCard: UIIcons.Shape.messageCircle
        case .modal: UIIcons.Layout.panelTop
        case .dialog: UIIcons.Shape.square
        case .alertDialog: UIIcons.Status.alertTriangle
        case .disclosure: UIIcons.Navigation.chevronDown
        case .accordion: UIIcons.Navigation.chevronRight
        case .tabs: UIIcons.File.folderOpen
        case .workspace: UIIcons.Media.monitor
        case .panel: UIIcons.Layout.panelRight
        case .sheet: UIIcons.Navigation.fullscreen
        case .bottomSheet: UIIcons.Layout.panelBottom
        case .actionSheet: UIIcons.Action.share
        case .splitView: UIIcons.Layout.columns2
        case .scrollView: UIIcons.Navigation.arrowDown
        case .boundedScroll: UIIcons.Navigation.minimize
        case .propertyGrid: UIIcons.Action.settings
        case .form: UIIcons.File.fileText
        case .layout: UIIcons.Layout.indent
        case .masonry: UIIcons.Layout.columns3
        case .zStack: UIIcons.Editor.layers
        case .animation: UIIcons.Editor.play
        case .badge: UIIcons.Shape.tag
        case .tag: UIIcons.Status.bookmark
        case .alert: UIIcons.Status.alertCircle
        case .progress: UIIcons.Status.loader
        case .skeleton: UIIcons.Layout.rows2
        case .empty: UIIcons.File.inbox
        case .radio: UIIcons.Shape.circleDot
        case .notification: UIIcons.Status.bell
        case .sidebar: UIIcons.Layout.sidebar
        case .navigationDrawer: UIIcons.Layout.panelLeft
        case .navigationRail: UIIcons.Navigation.chevronsRight
        case .table: UIIcons.Layout.table
        case .dataTable: UIIcons.Layout.grid
        case .calendar, .datePicker, .dateRangePicker: UIIcons.Data.calendar
        case .timeField, .timePicker, .wheelPicker: UIIcons.Data.clock
        case .timeline: UIIcons.Data.activity
        case .breadcrumb: UIIcons.Navigation.arrowRight
        case .pagination: UIIcons.Navigation.arrowUpRight
        case .stepper: UIIcons.Action.checkCheck
        case .keyCap: UIIcons.Shape.key
        case .toolbar: UIIcons.Action.pencil
        case .appBar: UIIcons.Navigation.arrowUp
        case .link: UIIcons.Action.link
        case .statusBar: UIIcons.Action.minus
        }
    }
}
