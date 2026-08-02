import EditorCore
import GuavaUICompose
import GuavaUIRuntime
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
        ScrollView(.vertical, scrollbarGutter: .stable) {
            Column(alignment: .leading, spacing: 10) {
                if let request = store.pendingConfirmationRequest {
                    ConfirmationBatchView(app: app, request: request)
                        .id(request.batchID)
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
    @State private var selectedOptionIDs: [String: String]

    init(app: EditorApplication, request: ConfirmationRequestBatch) {
        self.app = app
        self.request = request
        _selectedOptionIDs = State(wrappedValue: Dictionary(uniqueKeysWithValues:
            request.questions.compactMap { question in
                let optionID = question.defaultOptionID ?? question.options.first?.id
                return optionID.map { (question.id, $0) }
            }
        ))
    }

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
                ConfirmationQuestionCard(
                    question: question,
                    selectedOptionID: Binding(
                        get: { selectedOptionIDs[question.id] },
                        set: { optionID in
                            if let optionID {
                                selectedOptionIDs[question.id] = optionID
                            } else {
                                selectedOptionIDs.removeValue(forKey: question.id)
                            }
                        }
                    )
                )
            }

            Row(alignment: .center, spacing: 8) {
                Button(L("Submit Decisions"),
                       isEnabled: selectedOptionIDs.count == request.questions.count) {
                    app.resolvePendingConfirmation(
                        pickedOptionIDsByQuestionID: selectedOptionIDs
                    )
                }
                .buttonStyle(.primary)
                Button(L("Discard All")) {
                    app.skipPendingConfirmation()
                }
                .buttonStyle(.secondary)
            }
        }
    }
}

private struct ConfirmationQuestionCard: View {
    let question: ConfirmationQuestion
    let selectedOptionID: Binding<String?>

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
                        Button(isSelected: selectedOptionID.wrappedValue == option.id,
                               action: {
                            selectedOptionID.wrappedValue = option.id
                        }) {
                            Text(option.labelShort)
                        }
                        .buttonStyle(.toggle)
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
