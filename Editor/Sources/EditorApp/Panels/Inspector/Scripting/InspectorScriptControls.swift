import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Identity, source navigation and structural actions stay in the behavior's
/// header. They are independent hit targets, outside its collapse button.
struct InspectorScriptHeaderActions: View {
    let group: EditorInspectorFieldGroup
    let fields: [EditorInspectorField]
    let document: ScriptWorkspaceDocument?
    let isEditable: Bool
    let isPaused: Bool
    let onOpenScript: ((String) -> Void)?
    @State private var isMenuPresented = false
    @State private var isChoosingScript = false

    var body: some View {
        Row(alignment: .center, spacing: 4) {
            Text(status.label).lineLimit(1).font(.caption).foregroundColor(status.color)
                .debugName("inspector-script-status-\(group.id)")
            if let identifier = group.sourceIdentifier, let onOpenScript {
                Button(icon: .resource(.svg(named: "script", in: EditorAppResourceBundle.bundle, subdirectory: "PanelIcons")),
                       size: 12, tooltip: L("Open Script")) { onOpenScript(identifier) }
                    .buttonStyle(.ghost)
                    .debugName("inspector-script-open-\(group.id)")
            }
            Popover(isPresented: $isMenuPresented, width: 220) {
                Text("···").font(.bodyStrong).padding(horizontal: 4, vertical: 3)
            } content: {
                Menu(isChoosingScript ? scriptEntries : actionEntries, width: 220, maxVisibleRows: 12,
                     onItemActivated: {})
            }
            .debugName("inspector-script-menu-\(group.id)")
        }
    }

    private var status: (label: String, color: SemanticColorRef) {
        if let document {
            if document.externalChange.requiresResolution { return (L("Source Changed"), .warning) }
            if document.isDirty || document.loadedRevision.map({ $0 != document.editRevision }) == true {
                if document.buildState.isBuilding { return (L("Building"), .accent) }
                if document.buildState.isFailed { return (L("Build failed"), .error) }
                return (L("Not Applied"), .warning)
            }
            if document.buildState.isFailed { return (L("Build failed"), .error) }
            if document.buildState.isBuilding { return (L("Building"), .accent) }
        }
        let label: String
        if case let .readOnly(value)? = fields.first(where: { $0.id == group.statusFieldID })?.value { label = value }
        else { label = "" }
        if isPaused && label == L("Running") { return (L("Paused"), .onSurfaceMuted) }
        return (label, label == L("Missing script") ? .error
            : label == L("Reload Pending") || label == L("Not Built") ? .warning : .onSurfaceMuted)
    }

    private var actionEntries: [MenuEntry] {
        var entries: [MenuEntry] = [.item(MenuItem(id: "change", title: L("Change Script…"), isEnabled: isEditable) {
            isChoosingScript = true
        })]
        for fieldID in group.actionFieldIDs {
            guard let field = fields.first(where: { $0.id == fieldID }),
                  case let .action(title, destructive, action) = field.value else { continue }
            entries.append(.item(MenuItem(id: fieldID, title: title, isEnabled: isEditable,
                                          role: destructive ? .destructive : .normal) {
                isChoosingScript = false
                isMenuPresented = false
                action()
            }))
        }
        return entries
    }

    private var scriptEntries: [MenuEntry] {
        guard case let .stringOptions(binding, options)? = fields.first(where: { $0.id == group.selectorFieldID })?.value else { return [] }
        return [.item(MenuItem(id: "back", title: L("Back")) { isChoosingScript = false })]
            + options.map { option in
                .item(MenuItem(id: option.value, title: option.label, isEnabled: isEditable,
                               isSelected: binding.wrappedValue == option.value) {
                    binding.wrappedValue = option.value
                    isChoosingScript = false
                    isMenuPresented = false
                })
            }
    }
}

struct InspectorScriptAddButton: View {
    let options: [EditorInspectorStringOption]
    let isEnabled: Bool
    let onAdd: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, isEnabled: isEnabled, width: 240) {
            Row(alignment: .center, spacing: 5) {
                Text("+").font(.caption).foregroundColor(.onSurfaceVariant)
                Text(L("Add Script")).font(.caption).foregroundColor(.onSurfaceVariant)
            }
            .padding(horizontal: 6, vertical: 4)
        } content: {
            Menu(options.map { option in
                .item(MenuItem(id: option.value, title: option.label, isEnabled: isEnabled) { onAdd(option.value) })
            }, width: 240, maxVisibleRows: 12, onItemActivated: { isPresented = false })
        }
        .debugName("inspector-add-script")
    }
}
