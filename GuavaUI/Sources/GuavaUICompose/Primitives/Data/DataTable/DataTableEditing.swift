import GuavaUIRuntime

extension DataTable {
    func cell(record: Record, rowID: ID, column: TableColumn<Record>) -> AnyView {
        if let draft = session.editing, draft.rowID == rowID, draft.columnID == column.id {
            return AnyView(TextField(text: Binding(get: { session.editing?.buffer ?? .empty }, set: { session.editing?.buffer = $0 })) { input in
                input.behavior.disabled = !options.isEnabled
                input.navigation.focusRequestID = draft.identity
                input.codeEditing.editHistory = nil
                input.events.onSubmit = { _ = commitEditing() }
                input.events.onBlur = { _ = commitEditing(restoresFocus: false) }
                input.events.onCancel = { session.editing = nil; session.focus.focus() }
                input.events.onChange = { _ in session.editing?.error = nil }
                input.events.onKeyDown = { event in
                    guard event.scancode == Scancode.tab else { return false }
                    guard commitEditing() else { return true }
                    let direction = event.modifiers.contains(.shift) ? -1 : 1
                    moveEditor(from: draft, direction: direction); return true
                }
            }.font(.label).padding(horizontal: 4, vertical: 2)
                .accessibility { $0.label = "Edit \(column.title)"; $0.state.isInvalid = draft.error != nil; $0.help = draft.error ?? "Return commits, Escape cancels" })
        }
        return AnyView(Box(direction: .row, alignItems: .center,
            justifyContent: column.layout.alignment == .leading ? .flexStart : column.layout.alignment == .trailing ? .flexEnd : .center) {
                column.content(record)
            }.padding(horizontal: 10, vertical: 4))
    }
    func beginEditing(row: Int, column: Int) {
        guard options.isEnabled, columns.indices.contains(column), row >= 0, row < model.count,
              let editor = columns[column].textEditing else { return }
        let id = model.rowID(at: row)
        if session.editing?.rowID == id, session.editing?.columnID == columns[column].id { return }
        guard commitEditing() else { return }
        session.editing = DataTableCellDraft(rowID: id, columnID: columns[column].id, buffer: TextBuffer(editor.text(model.record(at: row))))
        reveal(row: row, column: column)
    }
    @discardableResult
    func commitEditing(restoresFocus: Bool = true) -> Bool {
        guard let draft = session.editing else { return true }
        guard let editor = columns.first(where: { $0.id == draft.columnID })?.textEditing,
              model.record(for: draft.rowID) != nil else { session.editing = nil; return true }
        let value = draft.buffer.stringValue
        if let message = editor.validate?(value) { session.editing?.error = message; return false }
        session.editing = nil
        if value != draft.original.stringValue { model.updateRow(draft.rowID) { editor.update(&$0, value) } }
        if restoresFocus { session.focus.focus() }
        return true
    }
    private func moveEditor(from draft: DataTableCellDraft<ID>, direction: Int) {
        guard let row = model.index(for: draft.rowID), let column = columns.firstIndex(where: { $0.id == draft.columnID }) else { return }
        var nextColumn = column + direction
        while columns.indices.contains(nextColumn) {
            if columns[nextColumn].textEditing != nil { beginEditing(row: row, column: nextColumn); return }
            nextColumn += direction
        }
    }
}
