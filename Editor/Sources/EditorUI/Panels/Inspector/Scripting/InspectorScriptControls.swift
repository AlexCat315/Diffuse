import EditorCore
import CoveUI
import CoveUIRuntime

/// The trailing half of a script row: status, the on/off switch and one menu
/// for everything else (open, change, remove). Independent hit targets,
/// outside the row's collapse button.
struct InspectorScriptHeaderActions: View {
    let group: EditorInspectorFieldGroup
    let fields: [EditorInspectorField]
    let document: ScriptWorkspaceDocument?
    let isEditable: Bool
    let isPaused: Bool
    let onOpenScript: ((String) -> Void)?
    var isOn: Binding<Bool>?
    @State private var isMenuPresented = false
    @State private var isChoosingScript = false

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            if !status.label.isEmpty {
                Row(alignment: .center, spacing: 5) {
                    Box {}.frame(width: 6, height: 6).background(status.color).cornerRadius(3)
                    Text(status.label).lineLimit(1).font(.caption).foregroundColor(.onSurfaceMuted)
                }.frame(maxWidth: 96).clipped()
                    .debugName("inspector-script-status-\(group.id)")
            }
            if let isOn {
                Toggle(isOn: isOn, isEnabled: isEditable).controlSize(.small)
                    .accessibility { $0.label = L("Enabled") }
                    .debugName("inspector-script-enabled-\(group.id)")
            }
            Popover(isPresented: $isMenuPresented, width: 220, surface: .content, overflow: .flip) {
                Icon(UIIcons.Action.moreHorizontal, size: 13, color: .onSurfaceMuted)
                    .frame(width: 24, height: 24)
                    .accessibility { $0.label = L("More") }
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
        var entries: [MenuEntry] = []
        if let identifier = group.sourceIdentifier, let onOpenScript {
            entries.append(.item(MenuItem(id: "open", title: L("Open Script")) {
                isMenuPresented = false
                onOpenScript(identifier)
            }))
        }
        entries.append(.item(MenuItem(id: "change", title: L("Change Script…"), isEnabled: isEditable) {
            isChoosingScript = true
        }))
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

