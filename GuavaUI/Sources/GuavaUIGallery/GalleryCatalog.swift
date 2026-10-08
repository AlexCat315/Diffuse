import GuavaUICompose
import GuavaUIRuntime

public enum GalleryPage: String, CaseIterable, Sendable, Hashable {
    case introduction, button, checkbox, toggle, slider, rating, textField, textArea, codeEditor
    case numberField, vec3Field, colorField, select, jsonField, assetRef
    case list, tree, virtualList, virtualStack, chart, icon, image, avatar
    case menu, contextMenu, popover, modal, disclosure, tabs
    case panel, splitView, scrollView, boundedScroll, propertyGrid, workspace
    case layout, animation, theme, badge, alert, progress, empty
    case radio, form, combobox, notification, tooltip, sidebar
    case table, dataTable, calendar, datePicker, timeField
    case accordion, breadcrumb, pagination, buttonGroup, tag, keyCap, label, dialog, alertDialog, sheet

    public var entry: GalleryEntry { GalleryCatalog.entries.first { $0.page == self }! }
}

public struct GalleryEntry: Sendable {
    public let page: GalleryPage
    public let title: String
    public let category: String
    public let summary: String
    public init(_ page: GalleryPage, _ title: String, _ category: String, _ summary: String) {
        self.page = page; self.title = title; self.category = category; self.summary = summary
    }
}

public enum GalleryCatalog {
    public static let entries: [GalleryEntry] = [
        .init(.introduction, "Introduction", "Overview", "A living catalog of real GuavaUI components and their interaction states."),
        .init(.button, "Button", "Controls", "Action hierarchy, semantic variants, icons, loading and control density."),
        .init(.checkbox, "Checkbox", "Controls", "Unchecked, checked, mixed and disabled selection."),
        .init(.toggle, "Toggle / Switch", "Controls", "Boolean settings with pointer capture and keyboard activation."),
        .init(.slider, "Slider", "Controls", "Continuous and stepped values with pointer capture and keyboard control."),
        .init(.rating, "Rating", "Controls", "Whole and half stars, pointer preview, keyboard selection, read-only scores and density."),
        .init(.textField, "TextField", "Inputs", "Single-line input, password, clear action, adornments and character limits."),
        .init(.textArea, "TextArea", "Inputs", "Multiline text with wrapping, scrolling and a resize grip."),
        .init(.codeEditor, "Code Editor", "Inputs", "Rope text, visible lines, diagnostic and completion UI, undo and source navigation."),
        .init(.numberField, "NumberField", "Inputs", "Commit on submit or blur, bounded values and keyboard stepping."),
        .init(.vec3Field, "Vec3Field", "Inputs", "Three-axis editing, numeric constraints and mixed values."),
        .init(.colorField, "ColorField", "Inputs", "RGBA channels and hexadecimal color input in a popover."),
        .init(.select, "Select / EnumField", "Inputs", "Typed selection, disabled options and keyboard navigation."),
        .init(.jsonField, "JsonField", "Inputs", "Multiline JSON validation, formatting and revert."),
        .init(.assetRef, "AssetRef / DropTarget", "Inputs", "Typed asset references, picker, clear action and accepted kinds."),
        .init(.list, "List", "Data", "Single selection, arrow-key navigation and activation."),
        .init(.tree, "Tree", "Data", "Hierarchy, expansion, selection and search with automatic expansion."),
        .init(.virtualList, "VirtualList", "Data", "A fixed-height scroll window over ten thousand rows."),
        .init(.virtualStack, "VirtualStack", "Data", "Viewport-driven materialization and scroll-to-index."),
        .init(.chart, "Chart", "Data", "Sparklines, bars, multiple series, thresholds and markers."),
        .init(.icon, "Icon", "Data", "Bundled SVG resources tinted by the current semantic theme."),
        .init(.avatar, "Avatar", "Data", "Asynchronous images, Unicode initials, stable theme colors and overlapping member groups."),
        .init(.image, "Image", "Data", "Fit/fill/stretch, asynchronous loading, explicit errors and retry."),
        .init(.menu, "Menu", "Overlays", "Nested commands, keyboard navigation, checked states and scrollable menus."),
        .init(.contextMenu, "ContextMenu", "Overlays", "Right-click actions attached to a real target."),
        .init(.popover, "Popover", "Overlays", "Anchored overlays, flipping, dismissal and nested input."),
        .init(.modal, "Modal", "Overlays", "Focus confinement, Escape dismissal and restoration."),
        .init(.disclosure, "DisclosureGroup", "Navigation", "Caller-owned expansion with animated content."),
        .init(.tabs, "TabView", "Navigation", "Selected content, disabled tabs and arrow/Home/End navigation."),
        .init(.panel, "Panel", "Layout", "Themed panel headers and content slots."),
        .init(.splitView, "SplitView", "Layout", "Horizontal and vertical proportional layouts."),
        .init(.scrollView, "ScrollView", "Layout", "Nested scrolling, wheel routing and stable scrollbar gutters."),
        .init(.boundedScroll, "BoundedScrollView", "Layout", "Content-driven viewport height with minimum and maximum bounds."),
        .init(.propertyGrid, "PropertyGrid", "Layout", "Inspector rows, sections, custom sizing and empty state."),
        .init(.workspace, "Workspace / Dock", "Layout", "Draggable tabs, split layouts and document serialization."),
        .init(.layout, "Box / Row / Column", "Layout", "Alignment, spacing, flex sizing, spacers and dividers."),
        .init(.animation, "Animation", "Foundation", "Animated visibility and explicit state transitions."),
        .init(.theme, "Theme / Typography", "Foundation", "Light and dark semantic surfaces, text and status colors."),
        .init(.badge, "Badge", "Feedback", "Compact labels using semantic status tones."),
        .init(.alert, "Alert", "Feedback", "Inline feedback with a title, detail and status tone."),
        .init(.progress, "Progress / Spinner", "Feedback", "Bounded progress and a lifecycle-managed loading indicator."),
        .init(.empty, "EmptyState", "Feedback", "A useful explanation and a recovery action for empty content."),
        .init(.radio, "RadioGroup", "Controls", "One Tab stop, controlled selection and arrow-key navigation."),
        .init(.form, "Form", "Inputs", "Field layout, required values, validation summaries and submission state."),
        .init(.combobox, "Combobox", "Inputs", "Searchable typed options, keyboard highlight, empty results and clearing."),
        .init(.notification, "Notification", "Feedback", "Stable-ID replacement, queued toasts, expiry, hover pause and dismissal."),
        .init(.tooltip, "Tooltip", "Overlays", "Delayed pointer and keyboard-focus descriptions outside clipping."),
        .init(.sidebar, "Sidebar", "Navigation", "Grouped destinations, badges, disabled items and header/footer slots."),
        .init(.table, "Table", "Data", "Virtualized rows, stable sorting, selection, fixed headers and resizable columns."),
        .init(.dataTable, "DataTable", "Data", "Persistent large-data model, background sorting, frozen columns, multi-selection and cell editing."),
        .init(.calendar, "Calendar", "Inputs", "Calendar-aware month grids, disabled dates and keyboard day navigation."),
        .init(.datePicker, "DatePicker", "Inputs", "Optional date input with an anchored calendar and a clear action."),
        .init(.timeField, "TimeField", "Inputs", "Validated time drafts, bounded values, seconds and keyboard stepping."),
        .init(.accordion, "Accordion", "Navigation", "Controlled single or multiple expansion with grouped keyboard focus."),
        .init(.breadcrumb, "Breadcrumb", "Navigation", "Destination paths with a collapsed intermediate-item menu."),
        .init(.pagination, "Pagination", "Navigation", "Bounded page navigation, boundary states and compact page windows."),
        .init(.buttonGroup, "ButtonGroup", "Controls", "Controlled segments with one Tab stop and disabled-item navigation."),
        .init(.tag, "Tag", "Data", "Semantic tags with independent removal actions."),
        .init(.keyCap, "Kbd / KeyCap", "Data", "Platform-aware keyboard hints."),
        .init(.label, "Label", "Inputs", "Associated field labels, focus activation, required state and help."),
        .init(.dialog, "Dialog", "Overlays", "Structured headers, scrollable content and action slots."),
        .init(.alertDialog, "AlertDialog", "Overlays", "Confirmation and cancellation with loading and destructive roles."),
        .init(.sheet, "Sheet", "Overlays", "An edge panel using modal focus and dismissal policies.")
    ]
    public static var categories: [String] {
        entries.reduce(into: []) { result, entry in if !result.contains(entry.category) { result.append(entry.category) } }
    }
    public static func search(_ query: String) -> [GalleryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            let text = entry.title + " " + entry.category + " " + entry.summary
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
    public static func page(named name: String) -> GalleryPage? {
        entries.first { $0.page.rawValue.caseInsensitiveCompare(name) == .orderedSame || $0.title.caseInsensitiveCompare(name) == .orderedSame }?.page
    }
}

public struct GalleryOptions {
    public var size: ControlSize = .regular
    public var isEnabled = true
    public init() {}
}
