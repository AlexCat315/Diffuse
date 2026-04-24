import EditorCore
import GuavaUICompose
import IntentRuntime

struct ConfirmationHostPanel: View {
    let app: EditorApplication

    init(app: EditorApplication) {
        self.app = app
    }

    var body: some View {
        StoreScope(app.store) { store in
            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 10) {
                    if let request = store.state.pendingConfirmationRequest {
                        ConfirmationBatchView(app: app, request: request)
                    } else {
                        Box(direction: .column, alignItems: .stretch, spacing: 6) {
                            Text("No pending confirmation")
                                .font(.bodyStrong)
                            Text("Warn, required, and destructive AI actions will appear here before they mutate the scene.")
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                        .padding(10)
                        .background(.surfaceSunken)
                        .cornerRadius(2)
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 320)
        }
    }
}

private struct ConfirmationBatchView: View {
    let app: EditorApplication
    let request: ConfirmationRequestBatch

    init(app: EditorApplication, request: ConfirmationRequestBatch) {
        self.app = app
        self.request = request
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 10) {
            Box(direction: .column, alignItems: .stretch, spacing: 4) {
                Text("\(request.questions.count) item requires confirmation")
                    .font(.bodyStrong)
                Text("origin: \(request.origin)")
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

    init(app: EditorApplication, question: ConfirmationQuestion) {
        self.app = app
        self.question = question
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                Text(question.promptShort)
                    .font(.bodyStrong)
                    .flex()
                SeverityBadge(severity: question.severity, reversible: question.reversible)
            }

            if let detail = question.promptDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }

            Row(alignment: .center, spacing: 8) {
                for option in question.options {
                    let isDestructiveSkip = option.id == "skip" && question.severity == .destructive
                    Button(option.labelShort,
                           role: isDestructiveSkip ? .destructive : .normal) {
                        app.resolvePendingConfirmation(pickedOptionID: option.id)
                    }
                }
            }
        }
        .padding(10)
        .background(question.severity == .destructive ? .surfaceSunken : .surfaceOverlay)
        .cornerRadius(2)
    }
}

private struct SeverityBadge: View {
    let severity: ConfirmationSeverity
    let reversible: Bool

    init(severity: ConfirmationSeverity, reversible: Bool) {
        self.severity = severity
        self.reversible = reversible
    }

    var body: some View {
        let (label, color): (String, SemanticColorRef) = {
            switch severity {
            case .destructive: return (reversible ? "destructive" : "destructive ·  perm", .error)
            case .warn:        return ("warn", .warning)
            default:           return ("info", .onSurfaceMuted)
            }
        }()
        Text(label)
            .font(.label)
            .foregroundColor(color)
            .padding(horizontal: 6, vertical: 2)
            .background(.surfaceSunken)
            .cornerRadius(2)
    }
}