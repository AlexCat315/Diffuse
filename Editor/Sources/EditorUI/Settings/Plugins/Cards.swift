internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

struct PluginInspectionCard: View {
    let summary: EditorPluginInspectionSummary
    let isBusy: Bool
    let isAlreadyEnabled: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text("\(summary.name) · v\(summary.version)", lineLimit: 1)
                .font(.body)
                .foregroundColor(.onSurface)
            Text(summary.id, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            if !summary.description.isEmpty {
                Text(summary.description, lineLimit: 4)
                    .font(.caption)
                    .foregroundColor(.onSurface)
            }

            PluginInspectionField(label: L("Access"), value: accessLabel(summary.access))
            PluginInspectionField(
                label: L("Imports"),
                value: summary.imports.isEmpty ? L("None") : summary.imports.joined(separator: ", ")
            )
            PluginInspectionField(
                label: L("Host Capabilities"),
                value: summary.composableHostCapabilities.isEmpty
                    ? L("None")
                    : summary.composableHostCapabilities.joined(separator: ", ")
            )
            PluginInspectionField(label: L("Component SHA-256"),
                                  value: summary.componentHash)
            if !summary.processPermissions.isEmpty {
                PluginInspectionField(label: L("Allowed commands"), value: summary.processPermissions.joined(separator: "\n"))
            }
            PluginInspectionField(label: L("WIT SHA-256"),
                                  value: summary.witHash)

            Text("\(L("Capabilities")) (\(summary.capabilities.count))")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            for capability in summary.capabilities {
                PluginCapabilitySummaryRow(capability: capability)
            }

            if isAlreadyEnabled {
                Text(L("This plugin is already enabled."))
                    .font(.caption)
                    .foregroundColor(.warning)
            }

            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                Button(summary.hasReusableAuthorization
                           ? L("Enable Authorized Plugin")
                           : L("Authorize & Enable"),
                       isEnabled: !isBusy && !isAlreadyEnabled,
                       action: onEnable)
                    .buttonStyle(.primary)
                Button(L("Cancel"),
                       isEnabled: !isBusy,
                       action: onCancel)
                    .buttonStyle(.ghost)
            }
        }
        .padding(horizontal: 10, vertical: 10)
        .background(.surfaceRaised)
        .cornerRadius(8)
    }
}

private struct PluginCapabilitySummaryRow: View {
    let capability: EditorPluginCapabilitySummary

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            Text(capability.id, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurface)
            Text("\(accessLabel(capability.access)) · \(capability.schemaHash)", lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
    }
}

private struct PluginInspectionField: View {
    let label: String
    let value: String

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Text(value)
                .font(.caption)
                .foregroundColor(.onSurface)
        }
    }
}

struct EnabledPluginRow: View {
    let plugin: EditorPluginInspectionSummary
    let isBusy: Bool
    let onReload: () -> Void
    let onDisable: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text("\(plugin.name) · v\(plugin.version)", lineLimit: 1)
                .foregroundColor(.onSurface)
            Text("\(plugin.id) · \(accessLabel(plugin.access))", lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                Button(L("Reload"), isEnabled: !isBusy, action: onReload)
                    .buttonStyle(.secondary)
                Button(L("Disable"), isEnabled: !isBusy, action: onDisable)
                    .buttonStyle(.secondary)
                Button(L("Revoke Authorization"),
                       role: .destructive,
                       isEnabled: !isBusy,
                       action: onRevoke)
                    .buttonStyle(.destructive)
            }
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surfaceRaised)
        .cornerRadius(8)
    }
}

private func accessLabel(_ rawValue: String) -> String {
    switch rawValue {
    case "read": return L("Read Only")
    case "reversible_write": return L("Reversible Write")
    case "destructive_write": return L("Destructive Write")
    case "external_side_effect": return L("External Side Effect")
    default: return rawValue
    }
}
