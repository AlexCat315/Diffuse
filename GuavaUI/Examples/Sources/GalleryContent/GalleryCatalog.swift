import GuavaUI
import GuavaUIRuntime

public enum GalleryPage: String, CaseIterable, Sendable, Hashable {
    case introduction, button, checkbox, toggle, slider, rangeSlider, rating, textField, textArea, textEditor
    case numberField, vec3Field, colorField, select, jsonField, assetRef, searchField
    case list, multiSelectList, sectionedList, reorderableList, swipeList, refreshableList, scrollbar, tree, virtualList, virtualStack, chart, icon, image, web, avatar
    case menu, menuButton, contextMenu, popover, modal, disclosure, tabs
    case panel, splitView, scrollView, boundedScroll, propertyGrid, workspace
    case layout, zStack, animation, theme, badge, alert, progress, empty
    case radio, form, combobox, notification, tooltip, sidebar, navigationDrawer, navigationRail
    case table, dataTable, calendar, datePicker, dateRangePicker, timeField, wheelPicker
    case accordion, breadcrumb, pagination, buttonGroup, splitButton, tag, keyCap, label, dialog, alertDialog, sheet, bottomSheet
    case commandPalette, hoverCard, timeline, toolbar, appBar, navigationStack, dragAndDrop
    case link, statusBar, carousel, skeleton, stepper, viewportTraits, viewThatFits

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
        .init(.introduction, "Dashboard", "Overview", "A working composition of GuavaUI typography, surfaces, controls and live state."),
        .init(.button, "Button", "Controls", "Action hierarchy, semantic variants, icons, loading and control density."),
        .init(.checkbox, "Checkbox", "Controls", "Unchecked, checked, mixed and disabled selection."),
        .init(.toggle, "Toggle / Switch", "Controls", "Boolean settings with pointer capture and keyboard activation."),
        .init(.slider, "Slider", "Controls", "Continuous and stepped values with pointer capture and keyboard control."),
        .init(.rangeSlider, "RangeSlider", "Controls", "Two thumbs, active-thumb pointer control, minimum span and accessibility value."),
        .init(.rating, "Rating", "Controls", "Whole and half stars, pointer preview, keyboard selection, read-only scores and density."),
        .init(.textField, "TextField", "Inputs", "Single-line input, password, clear action, adornments and character limits."),
        .init(.searchField, "SearchField", "Inputs", "Query input with a leading search icon, clear action, submit and suggestion keyboard navigation."),
        .init(.textArea, "TextArea", "Inputs", "Multiline text with wrapping, scrolling and a resize grip."),
        .init(.textEditor, "Text Editor", "Inputs", "Multiline prose and code editing: syntax colours, indent guides, bracket matching, current-line treatment, completion and undo."),
        .init(.numberField, "NumberField", "Inputs", "Commit on submit or blur, bounded values and keyboard stepping."),
        .init(.vec3Field, "Vec3Field", "Inputs", "Three-axis editing, numeric constraints and mixed values."),
        .init(.colorField, "ColorField", "Inputs", "RGBA channels and hexadecimal color input in a popover."),
        .init(.select, "Select / EnumField", "Inputs", "Typed selection, disabled options and keyboard navigation."),
        .init(.jsonField, "JsonField", "Inputs", "Multiline JSON validation, formatting and revert."),
        .init(.assetRef, "AssetRef / DropTarget", "Inputs", "Typed asset references, picker, clear action and accepted kinds."),
        .init(.list, "List", "Data", "Single selection, arrow-key navigation and activation."),
        .init(.multiSelectList, "MultiSelectList", "Data", "Shift range, Cmd/Ctrl toggle, keyboard extension and select-all."),
        .init(.sectionedList, "SectionedList", "Data", "Sticky section headers and footers over the virtualized list contract."),
        .init(.reorderableList, "ReorderableList", "Data", "Drag handles, a drop indicator and keyboard moves over a caller-owned order."),
        .init(.swipeList, "SwipeList", "Data", "Trailing swipe actions on touch, plus an always-available row actions button and context menu."),
        .init(.refreshableList, "RefreshableList", "Data", "Touch pull-to-refresh with threshold damping, an idle/frozen indicator and Cmd+R."),
        .init(.scrollbar, "Scrollbar", "Data", "A focusable slider thumb bound to a ScrollView offset."),
        .init(.tree, "Tree", "Data", "Hierarchy, expansion, selection and search with automatic expansion."),
        .init(.virtualList, "VirtualList", "Data", "A fixed-height scroll window over ten thousand rows."),
        .init(.virtualStack, "VirtualStack", "Data", "Viewport-driven materialization and scroll-to-index."),
        .init(.chart, "Chart", "Data", "Sparklines, bars, multiple series, thresholds and markers."),
        .init(.icon, "Icon", "Data", "Bundled SVG resources tinted by the current semantic theme."),
        .init(.avatar, "Avatar", "Data", "Asynchronous images, Unicode initials, stable theme colors and overlapping member groups."),
        .init(.image, "Image", "Data", "Fit/fill/stretch, asynchronous loading, explicit errors and retry."),
        .init(.web, "WebView", "Data", "A native browser view hosted above the composed surface, with navigation, clipping and lifecycle."),
        .init(.menu, "Menu", "Overlays", "Nested commands, keyboard navigation, checked states and scrollable menus."),
        .init(.menuButton, "MenuButton", "Controls", "A button-triggered menu with regular trigger chrome, keyboard dismissal and action callbacks."),
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
        .init(.zStack, "ZStack / Overlay", "Layout", "Layered content, alignment, topmost hit testing and retained hidden branches."),
        .init(.animation, "Animation", "Foundation", "Visibility, curves, springs, keyframes, phases, loops, shared geometry, numeric transitions and completion."),
        .init(.viewportTraits, "Viewport Traits", "Foundation", "Width/height classes and orientation derived from the surface viewport."),
        .init(.viewThatFits, "ViewThatFits", "Foundation", "Threshold and intrinsic-width branch selection with retained subtrees."),
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
        .init(.sidebar, "Sidebar", "Navigation", "Retained adaptive sidebar, rail and drawer layouts, icons, badges and keyboard navigation."),
        .init(.navigationDrawer, "NavigationDrawer", "Navigation", "Modal destinations, fitted width, focus restoration, swipe dismissal and shared selection."),
        .init(.navigationRail, "NavigationRail", "Navigation", "Labeled and icon-only destinations, retained presentations, keyboard navigation and full accessible names."),
        .init(.appBar, "AppBar / NavigationBar", "Navigation", "Adaptive headings, back navigation, primary actions, overflow commands and host-owned safe areas."),
        .init(.table, "Table", "Data", "Virtualized rows, stable sorting, selection, fixed headers and resizable columns."),
        .init(.dataTable, "DataTable", "Data", "Persistent large-data model, background sorting, frozen columns, multi-selection and cell editing."),
        .init(.calendar, "Calendar", "Inputs", "Calendar-aware month grids, disabled dates and keyboard day navigation."),
        .init(.datePicker, "DatePicker", "Inputs", "Optional date input with an anchored calendar and a clear action."),
        .init(.dateRangePicker, "DateRangePicker", "Inputs", "Two-click range selection in a real calendar with endpoint and in-range highlighting."),
        .init(.timeField, "TimeField", "Inputs", "Validated time drafts, bounded values, seconds and keyboard stepping."),
        .init(.wheelPicker, "WheelPicker", "Inputs", "Five-row wheel selection with drag, wheel, keyboard, disabled rows and accessibility value actions."),
        .init(.accordion, "Accordion", "Navigation", "Controlled single or multiple expansion with grouped keyboard focus."),
        .init(.breadcrumb, "Breadcrumb", "Navigation", "Destination paths with a collapsed intermediate-item menu."),
        .init(.pagination, "Pagination", "Navigation", "Bounded page navigation, boundary states and compact page windows."),
        .init(.buttonGroup, "ButtonGroup", "Controls", "Controlled segments with one Tab stop and disabled-item navigation."),
        .init(.splitButton, "SplitButton", "Controls", "Primary action plus an adjacent menu trigger with independent disabled behavior."),
        .init(.tag, "Tag", "Data", "Semantic tags with independent removal actions."),
        .init(.keyCap, "Kbd / KeyCap", "Data", "Platform-aware keyboard hints."),
        .init(.label, "Label", "Inputs", "Associated field labels, focus activation, required state and help."),
        .init(.dialog, "Dialog", "Overlays", "Structured headers, scrollable content and action slots."),
        .init(.alertDialog, "AlertDialog", "Overlays", "Confirmation and cancellation with loading and destructive roles."),
        .init(.sheet, "Sheet", "Overlays", "An edge panel using modal focus and dismissal policies."),
        .init(.bottomSheet, "BottomSheet", "Overlays", "Detent heights, drag-to-expand/dismiss and a centered wide-surface fallback."),
        .init(.commandPalette, "Command Palette", "Overlays", "Ranked fuzzy search over commands with keyboard-first selection."),
        .init(.navigationStack, "NavigationStack", "Navigation", "A session-owned page stack with retained pages, push/pop motion and deep-link restore."),
        .init(.dragAndDrop, "Drag & Drop", "Data", "Typed drag payloads, portal previews and highlighted drop targets."),
        .init(.hoverCard, "HoverCard", "Overlays", "Delayed hover detail that survives the pointer moving onto the card."),
        .init(.timeline, "Timeline", "Data", "Ordered events on a rail with per-event outcome glyphs."),
        .init(.toolbar, "Toolbar", "Controls", "One height and spacing rhythm, grouped controls and separators."),
        .init(.link, "Link", "Controls", "In-flow navigation with contextual underlines, external hints and a link role."),
        .init(.statusBar, "StatusBar", "Layout", "A single-height window footer with leading and trailing context cells."),
        .init(.carousel, "Carousel", "Layout", "Paged content with drag, arrows, indicators and keyboard paging."),
        .init(.skeleton, "Skeleton", "Feedback", "Shaped loading placeholders, reduced motion and content transitions."),
        .init(.stepper, "Stepper", "Navigation", "Controlled workflow steps, independent outcomes, locked steps and keyboard navigation.")
    ]
    public static var categories: [String] {
        entries.reduce(into: []) { result, entry in if !result.contains(entry.category) { result.append(entry.category) } }
    }
    public static func search(_ query: String) -> [GalleryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            let text = entry.title + " " + entry.page.rawValue + " " + entry.category + " " + entry.summary
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
