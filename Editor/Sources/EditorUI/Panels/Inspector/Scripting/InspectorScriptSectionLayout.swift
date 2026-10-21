import EditorCore
import GuavaUI
import GuavaUIRuntime

/// Scripts follow the component model of mature engines: every bound script
/// is its own component card, not a row inside a "Scripts" container. The
/// card's header carries identity and state (icon, name, status, on/off, menu);
/// its first row references the source file; build messages are an inline
/// notice; then come the script's own properties. Scripts are added from the
/// Add Component picker. The registry selects this layout for the `script`
/// component, so the panel does not compare section identifiers to find it.
enum InspectorScriptSectionLayout {
    struct Context {
        var collapsedIDs: Set<String>
        var startsCollapsed: Bool
        var isEditable: Bool
        var isPaused: Bool
        var documents: [ScriptWorkspaceDocument]
        var onOpenScript: ((String) -> Void)?
        var row: (EditorInspectorField, String) -> PropertyGridRow
    }

    static func sections(for section: EditorInspectorSection,
                         context: Context) -> [PropertyGridSection] {
        guard !section.groups.isEmpty else {
            // A script component with nothing bound yet keeps its own card.
            return [PropertyGridSection(id: section.id, title: section.title,
                rows: section.fields.map { context.row($0, section.id) },
                isCollapsible: true, startsCollapsed: context.startsCollapsed, showsRowCount: false)]
        }
        return section.groups.map { group in card(for: group, in: section, context: context) }
    }

    private static func card(for group: EditorInspectorFieldGroup, in section: EditorInspectorSection,
                             context: Context) -> PropertyGridSection {
        let fields = group.fieldIDs.compactMap { id in section.fields.first { $0.id == id } }
        var isOn: Binding<Bool>?
        if case let .bool(binding)? = section.fields.first(where: { $0.id == group.enabledFieldID })?.value {
            isOn = binding
        }
        let document = context.documents.first { document in
            document.file.identifier == group.sourceIdentifier
                || document.file.legacyIdentifiers.contains(group.sourceIdentifier ?? "")
        }
        var rows: [PropertyGridRow] = []
        if let identifier = group.sourceIdentifier {
            rows.append(PropertyGridRow(id: "source", label: L("Source")) {
                ScriptSourceReference(name: document?.file.displayName ?? identifier,
                                      onOpen: context.onOpenScript.map { open in { open(identifier) } })
                    .debugName("inspector-script-source-\(group.id)")
            })
        }
        var previousGroup: String?
        for field in fields {
            if let propertyGroup = field.group, propertyGroup != previousGroup {
                rows.append(PropertyGridRow(id: "group-\(propertyGroup)", label: "", rowHeight: 22,
                                            layout: .fullWidth, sizing: .intrinsic) {
                    Text(propertyGroup).font(.caption).foregroundColor(.onSurfaceMuted)
                })
            }
            previousGroup = field.group
            if field.id.hasSuffix("-issues") || field.id.hasSuffix("-interface"),
               case .readOnly(let message) = field.value {
                rows.append(PropertyGridRow(id: field.id, label: "", layout: .fullWidth, sizing: .intrinsic) {
                    ScriptNotice(message: message, isWarning: field.id.hasSuffix("-issues"))
                        .debugName("inspector-script-message-\(group.id)/\(field.id)")
                })
            } else {
                rows.append(context.row(field, group.id))
            }
        }
        return PropertyGridSection(id: group.id, title: group.title,
            rows: rows,
            isCollapsible: true,
            startsCollapsed: context.collapsedIDs.contains(group.id),
            headerLeading: AnyView(Icon(UIIcons.File.fileCode, size: 13, color: .accent)),
            headerTrailing: AnyView(InspectorScriptHeaderActions(group: group, fields: section.fields,
                document: document, isEditable: context.isEditable, isPaused: context.isPaused,
                onOpenScript: context.onOpenScript, isOn: isOn)),
            showsRowCount: false)
    }
}

/// The script a card runs, as a reference field: like an asset slot, it names
/// the file and opens it.
private struct ScriptSourceReference: View {
    let name: String
    let onOpen: (() -> Void)?

    var body: some View {
        Button(isEnabled: onOpen != nil, tooltip: L("Open Script")) { onOpen?() } label: {
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.File.fileCode, size: 12, color: .onSurfaceMuted)
                Text(name + ".swift", lineLimit: 1).font(.body).foregroundColor(.onSurface)
                    .flex(1, shrink: 1).frame(minWidth: 0)
                Icon(UIIcons.Navigation.arrowUpRight, size: 11, color: .onSurfaceMuted)
            }
            .padding(horizontal: 8)
            .frame(width: .percent(100), height: .points(26), minWidth: 0)
            .background(.surfaceSunken)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .frame(width: .percent(100), minWidth: 0)
    }
}

/// A build or interface message inside a script card: a quiet inline notice
/// rather than loose caption text between properties.
private struct ScriptNotice: View {
    let message: String
    let isWarning: Bool

    var body: some View {
        Row(alignment: .top, spacing: 8) {
            Icon(isWarning ? UIIcons.Status.alertTriangle : UIIcons.Status.info, size: 12,
                 color: isWarning ? .warning : .onSurfaceMuted)
                .padding(EdgeInsets(top: 2))
            Text(message, lineLimit: 3).font(.caption)
                .foregroundColor(isWarning ? .warning : .onSurfaceVariant)
                .flex(1, shrink: 1).frame(minWidth: 0)
        }
        .padding(horizontal: 10, vertical: 8)
        .frame(width: .percent(100), minWidth: 0)
        .background(.surfaceSunken)
        .cornerRadius(8)
    }
}
