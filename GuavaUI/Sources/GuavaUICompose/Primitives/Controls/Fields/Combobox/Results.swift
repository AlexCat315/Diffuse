import GuavaUIRuntime

/// The list area under the search field. A refresh keeps the previous results
/// dimmed in place, so typing never makes the popover jump between states.
struct ComboboxResults<Value: Hashable, ResultList: View>: View {
    let phase: ComboboxSearchPhase
    let matches: [SelectOption<Value>]
    let emptyText: String
    let listHeight: Float
    let retry: () -> Void
    @ViewBuilder let list: () -> ResultList

    var body: some View {
        switch phase {
        case .loading where matches.isEmpty:
            status(icon: nil, text: "Searching…") { Spinner(size: 14) }
        case .failed(let message):
            status(icon: UIIcons.Status.alertCircle, text: message, tone: .error) {
                Button("Retry") { retry() }.buttonStyle(.ghost).controlSize(.small)
            }
        case .tooShort(let count):
            status(icon: nil, text: "Type at least \(count) character\(count == 1 ? "" : "s") to search")
        case .idle, .loaded, .loading:
            if matches.isEmpty {
                status(icon: nil, text: emptyText)
            } else {
                list().frame(height: listHeight).flex(0, shrink: 0)
                    .opacity(phase == .loading ? 0.55 : 1)
                    .accessibility { if phase == .loading { $0.help = "Updating results" } }
            }
        }
    }

    private func status(icon: BundleImageResource?, text: String, tone: SemanticColorRef = .onSurfaceMuted) -> some View {
        status(icon: icon, text: text, tone: tone) { EmptyView() }
    }

    private func status<Accessory: View>(icon: BundleImageResource?, text: String, tone: SemanticColorRef = .onSurfaceMuted,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        Row(alignment: .center, spacing: 8) {
            if let icon { Icon(icon, size: .small, color: tone).flex(0, shrink: 0).accessibilityHidden() }
            Text(text).font(.caption).foregroundColor(tone).flex(1, shrink: 1).frame(minWidth: 0)
            accessory()
        }
        .padding(horizontal: 8, vertical: 10)
        .accessibility { $0.role = .status; $0.label = text }
    }
}
