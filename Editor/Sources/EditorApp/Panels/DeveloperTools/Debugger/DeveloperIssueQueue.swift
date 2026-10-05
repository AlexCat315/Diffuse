import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperIssueQueue: View {
    let issues: [DeveloperDiagnosticIssue]
    let title: String
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
                .padding(horizontal: 10, vertical: 8)

            Column(alignment: .leading, spacing: 6) {
                for issue in issues {
                    DeveloperIssueRow(issue: issue,
                                      onOpenTarget: onOpenTarget)
                }
            }
            .padding(horizontal: 8, vertical: 0)
        }
    }
}

private struct DeveloperIssueRow: View {
    let issue: DeveloperDiagnosticIssue
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        Button(action: { onOpenTarget(issue.target) }) {
            Column(alignment: .leading, spacing: 5) {
                Row(alignment: .center, spacing: 8) {
                    DeveloperSeverityBadge(severity: issue.severity,
                                           text: issue.severity.rawValue)
                    Text(issue.scope.rawValue)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text(issue.title)
                        .lineLimit(1)
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                        .flex(1, shrink: 1)
                    Text(issue.target.label)
                        .font(.caption)
                        .foregroundColor(.accent)
                }

                Text(issue.primarySignal)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundColor(.onSurface)

                if !issue.evidence.isEmpty {
                    Text(issue.evidence.prefix(3).joined(separator: " | "))
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }

                Text(issue.recommendation)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 10, vertical: 8)
            .background(.surfaceSunken)
            .cornerRadius(6)
            .border(developerDiagnosticBorder(issue.severity), width: 1)
        }
        .buttonStyle(.plain)
    }
}

private struct DeveloperSeverityBadge: View {
    let severity: DeveloperDiagnosticSeverity
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .font(.caption)
            .foregroundColor(developerDiagnosticForeground(severity))
            .padding(horizontal: 7, vertical: 2)
            .background(developerDiagnosticBackground(severity))
            .cornerRadius(4)
    }
}
