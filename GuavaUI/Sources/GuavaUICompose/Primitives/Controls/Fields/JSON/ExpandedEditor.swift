private import Foundation
internal import GuavaUIRuntime

/// Expanded editing owns its chrome; the field owns the atomic draft transaction.
struct JsonExpandedEditor: View {
    let draft: Binding<TextBuffer>
    let labels: JsonFieldLabels
    let history: TextEditHistory
    let apply: () -> Void
    let cancel: () -> Void

    static func fit(_ geometry: inout ModalGeometry, _ size: CGSize) {
        if size.width < CGFloat(UIEnvironment.Viewport.compactMaximumWidth) {
            geometry.inset = 0
            geometry.width = Float(size.width)
            geometry.height = Float(size.height)
            geometry.cornerRadius = 0
        }
    }

    private var validation: JsonFieldValidation { JsonField.validate(draft.wrappedValue.stringValue) }

    var body: some View {
        SurfaceReader { surface in
            SafeArea {
                chrome(compact: surface.viewport.widthClass == .compact)
            }.flex(1, shrink: 1, basis: 0)
        }
    }

    private func chrome(compact: Bool) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
                header.flex(0, shrink: 0)
                Divider()
                TextField("{}", text: draft) { input in
                    input.layout.axis = .vertical
                    input.layout.maxVisibleLines = 128
                    input.codeEditing.showsLineNumbers = true
                    input.codeEditing.indentationWidth = 2
                    input.codeEditing.editHistory = history
                    input.events.onSubmit = apply
                    input.events.onCancel = cancel
                }
                .font(.mono).accessibilityLabel(labels.expand)
                .textFieldStyle(.editor)
                .frame(minHeight: 0).padding(8).flex(1, shrink: 1, basis: 0)
                .debugName("json-expanded-input")
                Divider()
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    status
                    ActionGroupLayout(stacks: compact) {
                        Button(labels.cancel, action: cancel).buttonStyle(.ghost)
                            .accessibilityLabel(labels.cancel).debugName("json-cancel")
                            .frame(width: compact ? .percent(100) : nil)
                        Button(labels.apply, isEnabled: validation.isAcceptable, action: apply)
                            .buttonStyle(.primary).accessibilityLabel(labels.apply).debugName("json-apply")
                            .frame(width: compact ? .percent(100) : nil)
                    }
                }.padding(horizontal: 14, vertical: 10).flex(0, shrink: 0)
            }
            .background(.surfaceFloating).clipped().flex(1, shrink: 1, basis: 0)
            .accessibility { $0.role = .dialog; $0.label = labels.expand }
            .debugName("json-expanded-editor")
    }

    private var header: some View {
        Row(alignment: .center, spacing: 6) {
            Text(labels.expand).truncatingTail().tooltip(labels.expand).font(.bodyStrong)
                .accessibility { $0.role = .heading; $0.label = labels.expand }
                .flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            Button(icon: .resource(UIIcons.Action.format), size: 14,
                   isEnabled: validation.isAcceptable, tooltip: labels.format, action: format)
                .buttonStyle(.ghost).flex(0, shrink: 0)
            Button(icon: .resource(UIIcons.Action.x), size: 12,
                   tooltip: labels.cancel, action: cancel).buttonStyle(.ghost).flex(0, shrink: 0)
        }.padding(horizontal: 14, vertical: 8)
    }

    @ViewBuilder private var status: some View {
        if case let .invalid(message) = validation {
            Text(message, lineLimit: 3).tooltip(message).font(.caption).foregroundColor(.error)
                .accessibility { $0.role = .status; $0.state.isInvalid = true }
        } else {
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.Action.check, size: 11, color: .success).accessibilityHidden()
                Text(validation == .empty ? labels.empty : labels.valid)
                    .font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
    }

    private func format() {
        let before = draft.wrappedValue
        guard let pretty = JsonField.prettyPrinted(before.stringValue) else { return }
        let after = TextBuffer(pretty)
        history.synchronize(before)
        history.record(before: .init(buffer: before, cursor: before.characterCount),
                       after: .init(buffer: after, cursor: after.characterCount), kind: .atomic,
                       time: ProcessInfo.processInfo.systemUptime)
        draft.wrappedValue = after
    }
}
