import GuavaUI
import GuavaUIRuntime

extension GalleryPage {
    var navigationIcon: BundleImageResource {
        switch self {
        case .introduction: UIIcons.Layout.dashboard
        case .button, .buttonGroup: UIIcons.Action.target
        case .checkbox: UIIcons.Shape.squareCheck
        case .toggle, .slider, .numberField, .vec3Field: UIIcons.Action.sliders
        case .rating: UIIcons.Status.star
        case .textField, .textArea, .label: UIIcons.Text.type
        case .searchField: UIIcons.Action.search
        case .codeEditor, .jsonField: UIIcons.Editor.code
        case .colorField, .theme: UIIcons.Editor.brush
        case .select, .combobox: UIIcons.Navigation.chevronsUpDown
        case .assetRef: UIIcons.Shape.paperclip
        case .list, .virtualList, .virtualStack: UIIcons.Text.list
        case .tree: UIIcons.Editor.gitBranch
        case .chart: UIIcons.Data.chartLine
        case .icon: UIIcons.Status.sparkles
        case .image, .carousel: UIIcons.Media.image
        case .avatar: UIIcons.User.user
        case .menu, .contextMenu, .commandPalette: UIIcons.Action.moreHorizontal
        case .popover, .tooltip, .hoverCard: UIIcons.Shape.messageSquare
        case .modal, .dialog, .alertDialog: UIIcons.Layout.panelTop
        case .disclosure, .accordion: UIIcons.Navigation.chevronDown
        case .tabs, .workspace: UIIcons.Editor.layers
        case .panel, .sheet: UIIcons.Layout.panelRight
        case .bottomSheet: UIIcons.Layout.panelBottom
        case .splitView: UIIcons.Layout.columns2
        case .scrollView, .boundedScroll: UIIcons.Navigation.arrowDown
        case .propertyGrid, .form: UIIcons.Action.settings
        case .layout: UIIcons.Layout.grid
        case .zStack: UIIcons.Editor.layers
        case .animation: UIIcons.Editor.play
        case .badge, .tag: UIIcons.Shape.tag
        case .alert: UIIcons.Status.alertCircle
        case .progress, .skeleton: UIIcons.Status.loader
        case .empty: UIIcons.File.inbox
        case .radio: UIIcons.Shape.circleDot
        case .notification: UIIcons.Status.bell
        case .sidebar, .navigationDrawer, .navigationRail: UIIcons.Layout.sidebar
        case .table, .dataTable: UIIcons.Layout.table
        case .calendar, .datePicker: UIIcons.Data.calendar
        case .timeField, .timeline: UIIcons.Data.clock
        case .breadcrumb, .pagination, .stepper: UIIcons.Navigation.arrowRight
        case .keyCap: UIIcons.Shape.key
        case .toolbar, .appBar: UIIcons.Layout.panelTop
        case .link: UIIcons.Action.link
        case .statusBar: UIIcons.Layout.panelBottom
        }
    }
}
