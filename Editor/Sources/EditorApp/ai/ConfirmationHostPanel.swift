import EditorCore
import GuavaUICompose
import IntentRuntime

/// Pending-AI-action confirmation panel: question cards on sunken wells with
/// severity badges and secondary option buttons.
struct ConfirmationHostPanel: View {
    let store: EditorStore
    let app: EditorApplication

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some View {
        ScrollView(.vertical) {
            Column(alignment: .leading, spacing: 10) {
                if let request = store.pendingConfirmationRequest {
                    ConfirmationBatchView(app: app, request: request)
                } else {
                    Column(alignment: .leading, spacing: 6) {
                        Text(L("No pending confirmation"))
                            .font(.bodyStrong)
                        Text(L("Warn, required, and destructive AI actions will appear here before they mutate the scene."))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .padding(horizontal: 10, vertical: 10)
                    .background(.surfaceSunken)
                    .cornerRadius(7)
                }
            }
            .padding(horizontal: 10, vertical: 10)
        }
        .frame(minWidth: 320)
    }
}

private struct ConfirmationBatchView: View {
    let app: EditorApplication
    let request: ConfirmationRequestBatch

    var body: some View {
        Column(alignment: .leading, spacing: 10) {
            Column(alignment: .leading, spacing: 4) {
                Text("\(request.questions.count) \(L("item(s) require confirmation"))")
                    .font(.bodyStrong)
                Text("\(L("Origin:")) \(request.origin)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }

            for question in request.questions {
                ConfirmationQuestionCard(app: app, question: question)
            }
        }
    }
}

private struct ConfirmationQuestionCard: View {
    let app: EditorApplication
    let question: ConfirmationQuestion

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                Text(question.promptShort)
                    .font(.bodyStrong)
                    .flex(1, shrink: 1)
                SeverityBadge(severity: question.severity, reversible: question.reversible)
            }

            if let detail = question.promptDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }

            Row(alignment: .center, spacing: 8) {
                for option in question.options {
                    AnyView(
                        Button(action: {
                            app.resolvePendingConfirmation(pickedOptionID: option.id)
                        }) {
                            Text(option.labelShort)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    )
                }
            }
        }
        .padding(horizontal: 10, vertical: 10)
        .background(.surfaceSunken)
        .cornerRadius(7)
    }
}

private struct SeverityBadge: View {
    let severity: ConfirmationSeverity
    let reversible: Bool

    var body: some View {
        let (label, color): (String, SemanticColorRef) = {
            switch severity {
            case .destructive: return (reversible ? "destructive" : "destructive ·  perm", .error)
            case .warn:        return ("warn", .warning)
            default:           return ("info", .onSurfaceMuted)
            }
        }()
        return Text(label)
            .font(.label)
            .foregroundColor(color)
            .padding(horizontal: 6, vertical: 2)
            .background(.surfaceVariant)
            .cornerRadius(5)
    }
}
