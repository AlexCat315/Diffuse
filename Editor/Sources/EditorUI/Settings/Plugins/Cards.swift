internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

/// What a plugin row shows, whether or not the plugin is loaded.
struct PluginListing {
    var id: String
    var name: String
    var description: String
    var version: Int?
    var access: String?
    var capabilityCount = 0
    var isBundled = false
    var glyph = PluginGlyph.Kind.package
    /// A short warning under the description, e.g. a missing command-line tool.
    var note: String?

    init(_ plugin: EditorPluginInspectionSummary) {
        id = plugin.id; name = plugin.name; description = plugin.description
        version = plugin.version; access = plugin.access; capabilityCount = plugin.capabilities.count
    }

    /// A plugin that ships with the editor; `loaded` adds what its host reported.
    init(bundled plugin: BundledPlugin, loaded: EditorPluginInspectionSummary?, missingCommand: String?) {
        id = plugin.id; name = plugin.name; description = plugin.description
        version = plugin.version; access = plugin.access; isBundled = true
        capabilityCount = loaded?.capabilities.count ?? 0
        switch plugin.host {
        case .versionControl: glyph = .versionControl
        case .application: glyph = plugin.commands.contains("sourcekit-lsp") ? .swift : .package
        }
        note = missingCommand.map { String(format: L("The %@ command-line tool is not installed."), $0) }
    }
}

/// One installed plugin: identity on the left, its switch and actions on the right.
struct PluginRow: View {
    let listing: PluginListing
    let isEnabled: Bool
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let actions: [MenuEntry]
    @State private var isMenuPresented = false

    var body: some View {
        Row(alignment: .center, spacing: 12) {
            PluginGlyph(kind: listing.glyph)
            Column(alignment: .leading, spacing: 4) {
                Row(alignment: .center, spacing: 6) {
                    Text(listing.name, lineLimit: 1).font(.bodyStrong)
                        .foregroundColor(isEnabled ? .onSurface : .onSurfaceVariant)
                    if let version = listing.version {
                        Text("v\(version)").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    if listing.isBundled { Badge(L("Built-in")) { $0.variant = .outline } }
                }
                Text(L(listing.description), lineLimit: 2).font(.caption).foregroundColor(.onSurfaceMuted)
                if let note = listing.note {
                    Row(alignment: .center, spacing: 5) {
                        Icon(UIIcons.Status.alertTriangle, size: 11, color: .warning)
                        Text(note, lineLimit: 2).font(.caption).foregroundColor(.warning)
                    }
                }
                if isEnabled, let access = listing.access {
                    Row(alignment: .center, spacing: 6) {
                        Badge(pluginAccessLabel(access), tone: pluginAccessTone(access)) { $0.icon = UIIcons.Status.shield }
                        if listing.capabilityCount > 0 {
                            Text(String(format: L("%d capabilities"), listing.capabilityCount))
                                .font(.caption).foregroundColor(.onSurfaceMuted)
                        }
                    }.padding(EdgeInsets(top: 2))
                }
            }.flex(1, shrink: 1).frame(minWidth: 0)
            if !actions.isEmpty {
                Popover(isPresented: $isMenuPresented, width: 220, placement: .bottomTrailing, surface: .content, overflow: .flip) {
                    Icon(UIIcons.Action.moreHorizontal, size: 14, color: .onSurfaceVariant)
                        .padding(5).accessibility { $0.label = L("More Actions") }
                } content: {
                    Menu(actions, width: 220, onItemActivated: { isMenuPresented = false })
                }
            }
            Toggle(isOn: Binding(get: { isEnabled }, set: onToggle), isEnabled: !isBusy)
                .accessibility { $0.label = listing.name }
        }
        .padding(12)
        .frame(width: .percent(100), minWidth: 0)
        .background(.surfaceRaised)
        .cornerRadius(10)
        .debugName("settings-plugin-row-\(listing.id)")
    }
}

/// Built-in plugins wear the mark of what they serve; packages get a neutral tile.
struct PluginGlyph: View {
    enum Kind { case swift, versionControl, package }
    let kind: Kind

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            switch kind {
            case .swift: FileIcon(path: "Plugin.swift", size: 20)
            case .versionControl: Icon(UIIcons.Editor.gitBranch, size: 18, color: .onSurfaceVariant)
            case .package: Icon(UIIcons.File.package, size: 18, color: .onSurfaceVariant)
            }
        }.frame(width: 36, height: 36).background(.surfaceVariant).cornerRadius(9)
    }
}

/// A package under review: what it is, what it may touch, then the decision.
/// Integrity details stay folded; they matter for audits, not for the choice.
struct PluginReviewCard: View {
    let summary: EditorPluginInspectionSummary
    let isBusy: Bool
    let isAlreadyEnabled: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void
    @State private var showsIntegrity = false

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 14) {
            Row(alignment: .center, spacing: 12) {
                PluginGlyph(kind: .package)
                Column(alignment: .leading, spacing: 3) {
                    Row(alignment: .center, spacing: 6) {
                        Text(String(format: L("Review %@"), summary.name), lineLimit: 1).font(.bodyStrong)
                        Text("v\(summary.version)").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    Text(summary.id, lineLimit: 1).font(.mono).foregroundColor(.onSurfaceMuted)
                }.flex(1, shrink: 1).frame(minWidth: 0)
                Badge(pluginAccessLabel(summary.access), tone: pluginAccessTone(summary.access)) { $0.icon = UIIcons.Status.shield }
            }
            if !summary.description.isEmpty {
                Text(summary.description, lineLimit: 4).font(.body).foregroundColor(.onSurfaceVariant)
            }
            section(String(format: L("Capabilities (%d)"), summary.capabilities.count)) {
                if summary.capabilities.isEmpty {
                    Text(L("None")).font(.caption).foregroundColor(.onSurfaceMuted)
                }
                for capability in summary.capabilities {
                    AnyView(Row(alignment: .center, spacing: 8) {
                        Text(capability.id, lineLimit: 1).font(.mono).foregroundColor(.onSurface).flex(1, shrink: 1).frame(minWidth: 0)
                        Badge(pluginAccessLabel(capability.access), tone: pluginAccessTone(capability.access)) { $0.variant = .outline }
                    })
                }
            }
            if !summary.processPermissions.isEmpty {
                section(L("Allowed commands")) {
                    for command in summary.processPermissions {
                        AnyView(Text(command, lineLimit: 1).font(.mono).foregroundColor(.onSurface))
                    }
                }
            }
            DisclosureGroup(L("Integrity"), isExpanded: $showsIntegrity) {
                Column(alignment: .leading, spacing: 8) {
                    fact(L("Imports"), summary.imports.isEmpty ? L("None") : summary.imports.joined(separator: ", "))
                    fact(L("Host Capabilities"), summary.composableHostCapabilities.isEmpty
                         ? L("None") : summary.composableHostCapabilities.joined(separator: ", "))
                    fact(L("Component SHA-256"), summary.componentHash)
                    fact(L("WIT SHA-256"), summary.witHash)
                }.padding(EdgeInsets(top: 6, leading: 18))
            }
            Row(alignment: .center, spacing: 8) {
                if isAlreadyEnabled {
                    Text(L("This plugin is already enabled.")).font(.caption).foregroundColor(.warning)
                }
                Spacer(minLength: 0)
                Button(L("Cancel"), isEnabled: !isBusy, action: onCancel).buttonStyle(.ghost)
                Button(summary.hasReusableAuthorization ? L("Enable Authorized Plugin") : L("Authorize & Enable"),
                       isEnabled: !isBusy && !isAlreadyEnabled, action: onEnable)
                    .buttonStyle(.primary).debugName("settings-plugin-enable")
            }
        }
        .padding(18)
        .frame(width: .percent(100), minWidth: 0)
        .background(.surface)
        .cornerRadius(10)
        .debugName("settings-plugin-review")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text(title).font(.label).foregroundColor(.onSurfaceVariant)
            Box(direction: .column, alignItems: .stretch, spacing: 6) { content() }
                .padding(10).background(.surfaceRaised).cornerRadius(8)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        Column(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.onSurfaceMuted)
            Text(value, lineLimit: 2).font(.mono).foregroundColor(.onSurfaceVariant)
        }
    }
}

func pluginAccessLabel(_ rawValue: String) -> String {
    switch rawValue {
    case "read": return L("Read Only")
    case "reversible_write": return L("Reversible Write")
    case "destructive_write": return L("Destructive Write")
    case "external_side_effect": return L("External Side Effect")
    default: return rawValue
    }
}

private func pluginAccessTone(_ rawValue: String) -> StatusTone {
    switch rawValue {
    case "read": return .success
    case "reversible_write": return .info
    case "destructive_write", "external_side_effect": return .warning
    default: return .neutral
    }
}
