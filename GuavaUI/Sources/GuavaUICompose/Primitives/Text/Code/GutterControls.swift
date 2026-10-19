internal import GuavaUIRuntime

struct TextGutterControls: View {
    private let session: TextGutterSession
    private var observation: Observed<TextGutterSession, Int>
    init(_ session: TextGutterSession) { self.session = session; observation = Observed(\.revision, on: session) }
    var body: some View {
        let _ = observation.wrappedValue
        let controls = session.controls
        return GutterKeyBoundary(session: session) {
          RovingFocusHost(enabledItems: controls.map { AnyHashable($0.id) },
            selection: { session.selectedControl }, onSelect: { session.selectedControl = $0 }) {
            Box {
                for control in controls {
                    makeControl(control, first: controls.first?.id)
                }
            }
          }
        }.frame(width: .percent(100), height: .percent(100))
    }
    private func makeControl(_ control: TextGutterControl, first: String?) -> AnyView {
        guard let field = session.field else { return AnyView(EmptyView()) }
        return AnyView(TextGutterAction(control: control, field: field, session: session)
            .frame(width: Float(control.frame.width), height: Float(control.frame.height))
            .absolutePosition(left: Float(control.frame.minX), top: Float(control.frame.minY))
            .modifier(RovingItemModifier(id: AnyHashable(control.id), isTabStop: first == control.id))
            .debugName("editor-gutter-\(control.id)").id(control.id))
    }
}

private struct GutterKeyBoundary<Content: View>: _PrimitiveView {
    let session: TextGutterSession
    @ViewBuilder let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            phase == .bubble && session.handleKey(event) ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}

private struct TextGutterAction: View {
    let control: TextGutterControl
    let field: TextField
    let session: TextGutterSession
    private var gutter: TextEditorGutter { field.codeEditing.gutter }
    private var breakpoint: TextBreakpoint? { gutter.breakpoints?.wrappedValue.first { $0.line == control.line } }
    private var markers: [TextGutterMarker] { session.markersByLine[control.line] ?? [] }
    private var collapsed: Bool { session.folds.collapsed.contains(control.line) }
    private var foldLabel: String { collapsed ? field.codeEditing.folding.labels.expand(control.line) : field.codeEditing.folding.labels.collapse(control.line) }
    private var breakpointLabel: String { breakpoint == nil ? gutter.labels.addBreakpoint(control.line) : gutter.labels.removeBreakpoint(control.line) }
    private var foldedBreakpoints: Int {
        guard let region = session.folds.regions[control.line] else { return 0 }
        return gutter.breakpoints?.wrappedValue.filter { $0.line > control.line && region.lines.contains($0.line) }.count ?? 0
    }
    private var foldedBreakpointColor: SemanticColorRef {
        guard let region = session.folds.regions[control.line] else { return .onSurfaceMuted }
        return gutter.breakpoints?.wrappedValue.contains { $0.line > control.line && region.lines.contains($0.line) && $0.state != .disabled } == true ? .error : .onSurfaceMuted
    }
    var body: AnyView {
        switch control.kind {
        case .breakpoint:
            return AnyView(Button(isEnabled: !field.behavior.disabled, tooltip: breakpointLabel,
                                  action: { session.toggleBreakpoint(control.line) }) { breakpointGlyph }
                .buttonStyle(GutterButtonStyle(size: control.frame.size)).accessibility {
                    $0.label = breakpointLabel; $0.state.isSelected = breakpoint != nil
                    $0.value = breakpoint.map { gutter.labels.breakpointState($0.state) } ?? ""
                }.modifier(RovingItemModifier(id: AnyHashable(control.id), isTabStop: session.controls.first?.id == control.id))
                .contextMenu(entries: { breakpointEntries }))
        case .fold, .summary:
            return AnyView(Button(isEnabled: !field.behavior.disabled, tooltip: foldLabel,
                                  action: { session.toggleFold(control.line) }) {
                if control.kind == .summary {
                    Box(direction: .row, alignItems: .center, spacing: 4) {
                        if foldedBreakpoints > 0 { Box {}.frame(width: 6, height: 6).background(foldedBreakpointColor).cornerRadius(3) }
                        Text("⋯ \(control.count)").font(.caption).foregroundColor(.onSurfaceMuted)
                    }.padding(horizontal: 6).background(.stateLayerHover).cornerRadius(4)
                } else {
                    Icon(collapsed ? UIIcons.Navigation.chevronRight : UIIcons.Navigation.chevronDown, size: .small, color: .onSurfaceMuted)
                }
            }.buttonStyle(GutterButtonStyle(size: control.frame.size)).accessibility {
                $0.label = foldLabel; $0.value = control.kind == .summary ? field.codeEditing.folding.labels.summary(control.count) : ""
                if control.kind == .summary && foldedBreakpoints > 0 { $0.value += ", " + field.codeEditing.folding.labels.hiddenBreakpoints(foldedBreakpoints) }
                $0.state.isExpanded = !collapsed
            })
        case .markers:
            if markers.count == 1, let marker = markers.first {
                return AnyView(Button(isEnabled: !field.behavior.disabled, tooltip: marker.label,
                                      action: { session.activateMarker(marker.id) }) {
                    Icon(marker.icon, size: .medium, color: marker.color.map { SemanticColorRef { [color = $0] _ in color } } ?? .accent)
                }.buttonStyle(GutterButtonStyle(size: control.frame.size)).accessibilityLabel(marker.label))
            }
            return AnyView(menu(label: gutter.labels.lineActions(control.line), entries: markerEntries) {
                Text("\(markers.count)").font(.caption).foregroundColor(.accent)
            })
        case .combined:
            var entries = markerEntries
            if gutter.breakpoints != nil {
                entries.insert(.item(MenuItem(id: "breakpoint", title: breakpointLabel) { session.toggleBreakpoint(control.line) }), at: 0)
                if let breakpoint {
                    entries.insert(.item(MenuItem(id: "enabled", title: breakpoint.state == .disabled
                        ? gutter.labels.enableBreakpoint(control.line) : gutter.labels.disableBreakpoint(control.line)) {
                        session.toggleBreakpointEnabled(control.line)
                    }), at: 1)
                }
            }
            if session.folds.regions[control.line] != nil {
                entries.append(.item(MenuItem(id: "fold", title: foldLabel) { session.toggleFold(control.line) }))
            }
            return AnyView(menu(label: gutter.labels.lineActions(control.line), entries: entries) {
                if breakpoint != nil { breakpointGlyph }
                else if let marker = markers.first { Icon(marker.icon, size: .medium, color: .accent) }
                else if session.folds.regions[control.line] != nil {
                    Icon(collapsed ? UIIcons.Navigation.chevronRight : UIIcons.Navigation.chevronDown, size: .small, color: .onSurfaceMuted)
                } else { Icon(UIIcons.Action.moreHorizontal, size: .small, color: .onSurfaceMuted) }
            })
        }
    }
    private var breakpointGlyph: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            if breakpoint == nil && gutter.executionLine == control.line {
                Icon(UIIcons.Navigation.arrowRight, size: .medium, color: .warning)
            } else {
                Box {}.frame(width: 10, height: 10).cornerRadius(5)
                    .background(breakpoint?.state == .enabled ? SemanticColorRef.error : .clear)
                    .border(breakpoint == nil ? .clear : breakpoint?.state == .disabled ? .onSurfaceMuted : .error, width: 1.5)
            }
        }
    }
    private var breakpointEntries: [MenuEntry] {
        var entries = [MenuEntry.item(MenuItem(id: "toggle", title: breakpointLabel) { session.toggleBreakpoint(control.line) })]
        if let breakpoint {
            entries.append(.item(MenuItem(id: "enabled", title: breakpoint.state == .disabled
                ? gutter.labels.enableBreakpoint(control.line) : gutter.labels.disableBreakpoint(control.line)) {
                session.toggleBreakpointEnabled(control.line)
            }))
        }
        return entries
    }
    private var markerEntries: [MenuEntry] {
        markers.map { marker in .item(MenuItem(id: marker.id, title: marker.label) { session.activateMarker(marker.id) }) }
    }
    private func menu<Label: View>(label: String, entries: [MenuEntry], @ViewBuilder content: () -> Label) -> some View {
        GutterActionMenu(label: label, entries: entries, enabled: !field.behavior.disabled, size: control.frame.size, content: content())
    }
}

private struct GutterActionMenu<Content: View>: View {
    let label: String
    let entries: [MenuEntry]
    let enabled: Bool
    let size: CGSize
    let content: Content
    @State private var presented = false
    var body: some View {
        var popover = Popover(isPresented: $presented, isEnabled: enabled, placement: .bottomLeading,
                              surface: .content, overflow: .flip, triggerStyle: AnyButtonStyle(GutterButtonStyle(size: size)),
                              label: { content }) {
            Menu(entries, onItemActivated: { presented = false })
        }
        popover.triggerDescription = PopoverTriggerDescription(label: label, help: label)
        return popover
    }
}

private struct GutterButtonStyle: ButtonStyle {
    let size: CGSize
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) { AnyView(configuration.label) }
            .frame(width: Float(size.width), height: Float(size.height))
            .background(configuration.isHovered || configuration.isPressed ? SemanticColorRef.stateLayerHover : .clear)
            .border(configuration.isFocused ? .focusRing : .clear, width: 1)
            .cornerRadius(4)
    }
}
