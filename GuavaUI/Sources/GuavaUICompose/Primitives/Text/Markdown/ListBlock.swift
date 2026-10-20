import GuavaUIRuntime

/// Bulleted, numbered and task lists. Markers sit in a fixed-width gutter on
/// the first line of their item, so wrapped lines and nested blocks align to
/// the item text rather than to the marker.
struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        let lastNumber = (list.start ?? 1) + max(0, list.items.count - 1)
        // Numbers are right-aligned in a gutter sized for the widest one.
        let gutter: Float = list.start == nil ? 18 : Float(String(lastNumber).count) * 8 + 12
        return Box(direction: .column, alignItems: .stretch, spacing: 6) {
            for (index, item) in list.items.enumerated() {
                AnyView(Box(direction: .row, alignItems: .flexStart, spacing: 6) {
                    marker(for: item, number: (list.start ?? 1) + index)
                        .frame(width: gutter)
                    Box(direction: .column, alignItems: .stretch, spacing: 6) {
                        for block in item.blocks {
                            AnyView(MarkdownBlockView(block: block, depth: depth + 1, onOpenLink: onOpenLink))
                        }
                    }
                    .flex(1, shrink: 1, basis: 0)
                })
            }
        }
    }

    private func marker(for item: MarkdownList.Item, number: Int) -> AnyView {
        if let checked = item.isChecked {
            return AnyView(MarkdownTaskMarker(isChecked: checked))
        }
        guard list.start == nil else {
            return AnyView(RichText([RichTextRun("\(number).")], alignment: .trailing)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: .percent(100)))
        }
        return AnyView(MarkdownFirstLine { MarkdownBullet(depth: depth) })
    }
}

/// Drawn rather than typeset: a font's bullet glyph is often too small to
/// read as a marker. Nesting alternates dot, ring and square.
private struct MarkdownBullet: View {
    let depth: Int

    var body: some View {
        switch depth % 3 {
        case 0: AnyView(Box(direction: .row) {}.frame(width: 6, height: 6).background(.onSurfaceMuted).cornerRadius(3))
        case 1: AnyView(Box(direction: .row) {}.frame(width: 6, height: 6).cornerRadius(3).border(.onSurfaceMuted, width: 1.5))
        default: AnyView(Box(direction: .row) {}.frame(width: 5, height: 5).background(.onSurfaceMuted).cornerRadius(1))
        }
    }
}

/// Centres a marker on the height of a body line, so it aligns with the
/// first line of its item.
private struct MarkdownFirstLine<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        TextScalerReader { scaler in
            ThemeReader { theme in
                Box(direction: .row, alignItems: .center, justifyContent: .center) { content }
                    .frame(width: .percent(100), height: .points(scaler.scale(theme.typography.body.lineHeight)))
            }
        }
    }
}

/// A read-only checkbox glyph centred on the item's first line.
private struct MarkdownTaskMarker: View {
    let isChecked: Bool

    var body: some View {
        MarkdownFirstLine {
            if isChecked {
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Icon(UIIcons.Action.check, size: .small, color: .onAccent)
                }
                .frame(width: 15, height: 15).background(.accent).cornerRadius(4)
            } else {
                Box(direction: .row) {}.frame(width: 15, height: 15).cornerRadius(4).border(.borderStrong, width: 1.5)
            }
        }
        .accessibility {
            $0.role = .checkbox
            $0.label = isChecked ? "Completed" : "Not completed"
            $0.state.isSelected = isChecked
            $0.state.isReadOnly = true
        }
    }
}
