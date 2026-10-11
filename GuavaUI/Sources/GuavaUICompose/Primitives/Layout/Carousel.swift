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
/// ]) { $0.height = 180 }
/// ```
public struct Carousel<ID: Hashable>: View {
    public var pages: [CarouselPage<ID>]
    /// Caller-owned selection. `nil` keeps the current page inside the view.
    public var selection: Binding<ID>?
    public var showsArrows = true
    public var showsIndicators = true
    /// Wrapping keeps the gesture useful on the last page; turn it off for
    /// onboarding flows that must end.
    public var allowsWrap = true
    public var height: Float? = nil
    public var isEnabled = true

    @State private var internalSelection: ID?

    public init(pages: [CarouselPage<ID>],
                selection: Binding<ID>? = nil,
                configure: (inout Self) -> Void = { _ in }) {
        self.pages = pages
        self.selection = selection
        configure(&self)
    }

    public var body: some View {
        ThemeReader { theme in
            SelectionKeyHost(isEnabled: isEnabled && !pages.isEmpty, onKey: handleKey) {
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
                    $0.value = pages.isEmpty ? "No pages" : "Page \(currentIndex + 1) of \(pages.count)"
                    $0.state.isEnabled = isEnabled
                }
                .opacity(isEnabled ? 1 : 0.55)
            }
        }
    }

    // MARK: - Structure

    @ViewBuilder private func viewport(in theme: Theme) -> some View {
        let row = Box(direction: .row, alignItems: .stretch, spacing: theme.spacing.sm) {
            if showsArrows, pages.count > 1 { AnyView(stepButton(-1)) }
            AnyView(CarouselSwipeHost(onSwipe: { move($0) },
                                       isEnabled: isEnabled && pages.count > 1) {
                AnyView(currentPage?.content ?? AnyView(EmptyView())).id(currentPage?.id)
            }
            .flex()
            .clipped()
            .cornerRadius(theme.radius.md)
            .background(theme.colors.surfaceSunken))
            if showsArrows, pages.count > 1 { AnyView(stepButton(1)) }
        }
        if let height { AnyView(row.frame(height: height.isFinite ? max(1, height) : 180)) } else { AnyView(row) }
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
                .frame(width: 24, height: 24))
            }
        }
    }

    private func stepButton(_ delta: Int) -> some View {
        let isEnabled = isEnabled && (allowsWrap || canStep(delta))
        return Button(isEnabled: isEnabled,
                      tooltip: delta < 0 ? "Previous" : "Next",
                      action: { move(delta) }) {
            Icon(delta < 0 ? UIIcons.Navigation.chevronLeft : UIIcons.Navigation.chevronRight, size: .medium)
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
        guard isEnabled, pages.indices.contains(index) else { return }
        let id = pages[index].id
        if let selection { selection.wrappedValue = id } else { internalSelection = id }
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        guard isEnabled, pages.count > 1, event.modifiers.isEmpty else { return false }
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
