import GuavaUIRuntime

/// The pane presented when a split has room for only one pane.
public enum SplitPane: Sendable, Hashable {
    case first, second
}

/// Opt-in single-pane presentation, measured along the split's allocated axis.
/// Pane titles are supplied by the application for localization and accessibility.
public struct SplitCompactPresentation {
    public let firstTitle: String
    public let secondTitle: String
    public var threshold: Float = 600
    /// Omit to let the split retain its own selection, initially `.first`.
    public var selection: Binding<SplitPane>?

    public init(firstTitle: String, secondTitle: String, configure: (inout Self) -> Void = { _ in }) {
        self.firstTitle = firstTitle
        self.secondTitle = secondTitle
        configure(&self)
    }

    var resolvedThreshold: Float { threshold.isFinite ? max(0, threshold) : 600 }
}

struct SplitPaneSelector: View {
    let presentation: SplitCompactPresentation
    let selection: Binding<SplitPane>

    var body: some View {
        RovingFocusHost(
            enabledItems: [AnyHashable(SplitPane.first), AnyHashable(SplitPane.second)],
            selection: { AnyHashable(selection.wrappedValue) },
            onSelect: { if let pane = $0.base as? SplitPane { selection.wrappedValue = pane } }
        ) {
            Box(direction: .row, alignItems: .stretch) {
                item(.first, title: presentation.firstTitle)
                item(.second, title: presentation.secondTitle)
            }
        }.accessibility {
            $0.role = .group
            $0.label = "Choose split pane"
        }
    }

    private func item(_ pane: SplitPane, title: String) -> some View {
        Button(isSelected: selection.wrappedValue == pane, action: { selection.wrappedValue = pane }) {
            Text(title, alignment: .center).flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
        }
        .buttonStyle(SplitPaneButtonStyle())
        .accessibility {
            $0.role = .tab
            $0.label = title
            $0.state.isSelected = selection.wrappedValue == pane
        }
        .modifier(RovingItemModifier(id: AnyHashable(pane), isTabStop: selection.wrappedValue == pane))
        .flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
    }
}

private struct SplitPaneButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        TabButtonStyle().makeBody(configuration: configuration).frame(width: .percent(100))
    }
}
