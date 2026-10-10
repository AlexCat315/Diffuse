import GuavaUIRuntime

/// One page of a `Carousel`.
public struct CarouselPage<ID: Hashable>: Identifiable {
    public let id: ID
    /// Optional line shown under the viewport; changes with the page.
    public var caption: String
    public let content: AnyView

    public init<C: View>(_ id: ID,
                         caption: String = "",
                         @ViewBuilder content: () -> C) {
        self.id = id
        self.caption = caption
        self.content = AnyView(content())
    }
}

/// A paged view: one page fills the viewport, the rest are one gesture away.
///
/// Paging is worth the extra chrome only when the pages are meaningfully
/// different views rather than a row that could have been scrolled, so the
/// component commits to it: arrows at the edges, indicators underneath,
/// left/right/Home/End on the keyboard, and a horizontal drag with the same
/// threshold-based feel as a native swipe.
///
/// ```swift
/// Carousel(pages: [
///     CarouselPage("intro", caption: "Welcome") { IntroCard() },
///     CarouselPage("themes", caption: "Themes") { ThemeCard() }
/// ], height: 180)
/// ```
public struct Carousel<ID: Hashable>: View {
    public var pages: [CarouselPage<ID>]
    /// Caller-owned selection. `nil` keeps the current page inside the view.
    public var selection: Binding<ID>?
    public var showsArrows: Bool
    public var showsIndicators: Bool
    /// Wrapping keeps the gesture useful on the last page; turn it off for
    /// onboarding flows that must end.
    public var allowsWrap: Bool
    public var height: Float?
    public var isEnabled: Bool

    @State private var internalSelection: ID?

    public init(pages: [CarouselPage<ID>],
                selection: Binding<ID>? = nil,
                configure: (inout Self) -> Void = { _ in }) {
        self.pages = pages
        self.selection = selection
        self.showsArrows = true
        self.showsIndicators = true
        self.allowsWrap = true
        self.height = nil
        self.isEnabled = true
        configure(&self)
    }

    public var body: some View {
        ThemeReader { theme in
            SelectionKeyHost(onKey: handleKey) {
                Column(alignment: .center, spacing: theme.spacing.sm) {
                    AnyView(viewport(in: theme))
                    if showsIndicators, pages.count > 1 {
                        AnyView(indicators(in: theme))
                    }
                    if let caption = currentPage?.caption, !caption.isEmpty {
                        AnyView(Text(caption)
                            .font(.caption)
                            .foregroundColor(theme.colors.onSurfaceMuted))
                    }
                }
                .accessibility {
                    $0.role = .group
                    $0.label = "Carousel"
                    $0.value = "Page \(currentIndex + 1) of \(pages.count)"
                    $0.state.isEnabled = isEnabled
                }
            }
        }
    }

    // MARK: - Structure

    @ViewBuilder private func viewport(in theme: Theme) -> some View {
        let row = Box(direction: .row, alignItems: .stretch, spacing: theme.spacing.sm) {
            if showsArrows, pages.count > 1 { AnyView(stepButton(-1)) }
            AnyView(_CarouselSwipeHost(onSwipe: { move($0) },
                                       isEnabled: isEnabled && pages.count > 1) {
                AnyView(currentPage?.content ?? AnyView(EmptyView()))
            }
            .flex()
            .clipped()
            .cornerRadius(theme.radius.md)
            .background(theme.colors.surfaceSunken))
            if showsArrows, pages.count > 1 { AnyView(stepButton(1)) }
        }
        if let height { AnyView(row.frame(height: height)) } else { AnyView(row) }
    }

    @ViewBuilder private func indicators(in theme: Theme) -> some View {
        Row(alignment: .center, spacing: 6) {
            for index in pages.indices {
                AnyView(Button(isEnabled: isEnabled,
                               tooltip: "Page \(index + 1)",
                               action: { go(to: index) }) {
                    Box(direction: .row, alignItems: .center, spacing: 0) {}
                        .frame(width: index == currentIndex ? 16 : 7, height: 7)
                        .background(index == currentIndex ? theme.colors.accent : theme.colors.onSurfaceMuted)
                        .cornerRadius(3.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1)")
                .accessibility { $0.state.isSelected = index == currentIndex }
                .padding(2))
            }
        }
    }

    private func stepButton(_ delta: Int) -> some View {
        let isEnabled = isEnabled && (allowsWrap || canStep(delta))
        return Button(isEnabled: isEnabled,
                      tooltip: delta < 0 ? "Previous" : "Next",
                      action: { move(delta) }) {
            Icon(delta < 0 ? UIIcons.Navigation.chevronLeft : UIIcons.Navigation.chevronRight, size: 14)
        }
        .buttonStyle(.ghost)
        .controlSize(.small)
        .accessibilityLabel(delta < 0 ? "Previous page" : "Next page")
    }

    // MARK: - Selection

    private var activeID: ID? {
        selection?.wrappedValue ?? internalSelection ?? pages.first?.id
    }
    private var currentIndex: Int {
        guard let activeID else { return 0 }
        return pages.firstIndex { $0.id == activeID } ?? 0
    }
    private var currentPage: CarouselPage<ID>? {
        pages.isEmpty ? nil : pages[currentIndex]
    }

    private func canStep(_ delta: Int) -> Bool {
        delta < 0 ? currentIndex > 0 : currentIndex < pages.count - 1
    }

    private func move(_ delta: Int) {
        guard isEnabled, !pages.isEmpty else { return }
        go(to: allowsWrap
            ? (currentIndex + delta + pages.count) % pages.count
            : min(pages.count - 1, max(0, currentIndex + delta)))
    }

    private func go(to index: Int) {
        guard pages.indices.contains(index) else { return }
        let id = pages[index].id
        if let selection { selection.wrappedValue = id } else { internalSelection = id }
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        guard isEnabled, pages.count > 1 else { return false }
        switch event.scancode {
        case Scancode.arrowLeft: move(-1)
        case Scancode.arrowRight: move(1)
        case Scancode.home: go(to: 0)
        case Scancode.end: go(to: pages.count - 1)
        default: return false
        }
        return true
    }
}

// MARK: - Swipe gesture

/// Recognises a horizontal drag on the page area.
///
/// Capture is acquired only once the pointer has travelled far enough to be a
/// swipe, so a page keeps its own buttons and links: taps inside the page are
/// never swallowed, and a drag that turns out to be vertical is released back
/// to whatever is underneath.
private enum CarouselSwipe {
    static let hostKey = "carousel-swipe-host"
    static let startXKey = "carousel-swipe-start-x"
    static let startYKey = "carousel-swipe-start-y"
    static let draggingKey = "carousel-swipe-dragging"
    /// Movement that turns a press into a swipe.
    static let slop: Float = 8
}

private struct _CarouselSwipeHost<Content: View>: _PrimitiveView {
    let onSwipe: (Int) -> Void
    let isEnabled: Bool
    let content: Content

    init(onSwipe: @escaping (Int) -> Void,
         isEnabled: Bool,
         @ViewBuilder content: () -> Content) {
        self.onSwipe = onSwipe
        self.isEnabled = isEnabled
        self.content = content()
    }

    func _makeNode() -> Node { Node() }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }

    func _updateNode(_ node: Node) {
        node.isHitTestable = true
        node.clipsToBounds = true
        node.attachments[CarouselSwipe.hostKey] = true
        let registry = InteractionRegistryHolder.current
        registry?.setPointer(node) { event, phase, eventPhase in
            guard isEnabled, eventPhase != .capture, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[CarouselSwipe.startXKey] = Float(event.x)
                node.attachments[CarouselSwipe.startYKey] = Float(event.y)
                node.attachments[CarouselSwipe.draggingKey] = false
                // Ignored on purpose: the page's own controls get the press
                // first and only a real drag takes the gesture away from them.
                return .ignored
            case .up:
                release(node)
                return .ignored
            }
        }
        registry?.setMotion(node) { event, _ in
            guard isEnabled,
                  let startX = node.attachments[CarouselSwipe.startXKey] as? Float,
                  let startY = node.attachments[CarouselSwipe.startYKey] as? Float else { return .ignored }
            let dx = Float(event.x) - startX
            let dy = Float(event.y) - startY
            let isDragging = (node.attachments[CarouselSwipe.draggingKey] as? Bool) ?? false
            if !isDragging {
                guard abs(dx) >= CarouselSwipe.slop, abs(dx) > abs(dy) else { return .ignored }
                node.attachments[CarouselSwipe.draggingKey] = true
                PointerCaptureHolder.current?.acquire(node)
            }
            // A fresh swipe every time the pointer crosses the threshold, so a
            // long drag can page through several slides instead of one.
            let threshold = max(32, Float(node.frame.width) * 0.15)
            if abs(dx) >= threshold {
                node.attachments[CarouselSwipe.startXKey] = Float(event.x)
                node.attachments[CarouselSwipe.startYKey] = Float(event.y)
                onSwipe(dx < 0 ? 1 : -1)
            }
            return .handled
        }
    }

    private func release(_ node: Node) {
        if (node.attachments[CarouselSwipe.draggingKey] as? Bool) == true {
            PointerCaptureHolder.current?.release()
        }
        node.attachments[CarouselSwipe.startXKey] = nil
        node.attachments[CarouselSwipe.startYKey] = nil
        node.attachments[CarouselSwipe.draggingKey] = false
    }

    var _children: [any View] { [content] }
}
