import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Lays out one script binding per collapsible child section. The registry
/// selects this layout for the `script` component, so the panel does not compare
/// section identifiers to find it.
enum InspectorScriptSectionLayout {
    struct Context {
        var collapsedIDs: Set<String>
        var startsCollapsed: Bool
        var isEditable: Bool
        var isPaused: Bool
        var canAddScript: Bool
        var documents: [ScriptWorkspaceDocument]
        var addOptions: [EditorInspectorStringOption]
        var onOpenScript: ((String) -> Void)?
        var addScript: (String) -> Void
        var row: (EditorInspectorField, String) -> PropertyGridRow
    }

    static func sections(for section: EditorInspectorSection,
                         context: Context) -> [PropertyGridSection] {
        let children = section.groups.map { group -> PropertyGridSection in
            let fields = group.fieldIDs.compactMap { id in section.fields.first { $0.id == id } }
            let enabled = section.fields.first { $0.id == group.enabledFieldID }
            let leading: AnyView?
            if case let .bool(binding)? = enabled?.value {
                leading = AnyView(Checkbox(isOn: binding, isEnabled: context.isEditable)
                    .debugName("inspector-script-enabled-\(group.id)"))
            } else { leading = nil }
            let document = context.documents.first { document in
                document.file.identifier == group.sourceIdentifier
                    || document.file.legacyIdentifiers.contains(group.sourceIdentifier ?? "")
            }
            var rows: [PropertyGridRow] = []
            var previousGroup: String?
            for field in fields {
                if let propertyGroup = field.group, propertyGroup != previousGroup {
                    rows.append(PropertyGridRow(id: "group-\(propertyGroup)", label: "", rowHeight: 22,
                                                layout: .fullWidth, sizing: .intrinsic) {
                        Text(propertyGroup).font(.caption).foregroundColor(.onSurfaceVariant)
                    })
                }
                previousGroup = field.group
                if field.id.hasSuffix("-issues") || field.id.hasSuffix("-interface"),
                   case .readOnly(let message) = field.value {
                    rows.append(PropertyGridRow(id: field.id, label: "", layout: .fullWidth, sizing: .intrinsic) {
                        Text(message, lineLimit: 3).font(.caption)
                            .foregroundColor(field.id.hasSuffix("-issues") ? .warning : .onSurfaceMuted)
                            .debugName("inspector-script-message-\(group.id)/\(field.id)")
                    })
                } else {
                    rows.append(context.row(field, group.id))
                }
            }
            return PropertyGridSection(id: group.id, title: group.title,
                rows: rows,
                isCollapsible: true, startsCollapsed: context.startsCollapsed,
                headerLeading: leading,
                headerTrailing: AnyView(InspectorScriptHeaderActions(group: group, fields: section.fields,
                    document: document, isEditable: context.isEditable, isPaused: context.isPaused,
                    onOpenScript: context.onOpenScript)),
                showsRowCount: false)
        }
        let emptyFields = section.groups.isEmpty ? section.fields.filter { $0.id != "script-add" } : []
        let footer = AnyView(InspectorScriptAddButton(options: context.addOptions,
            isEnabled: context.canAddScript, onAdd: context.addScript))
        return [PropertyGridSection(id: section.id, title: section.title,
            rows: emptyFields.map { context.row($0, section.id) },
            isCollapsible: true, startsCollapsed: context.startsCollapsed, children: children,
            footer: footer, badge: String(section.groups.count), showsRowCount: false)]
    }
}
