import GuavaUICompose
import GuavaUIRuntime

/// Text field that edits a local draft and writes the binding once, on blur
/// or Return — instead of per keystroke. Model-side normalization (e.g.
/// "entity names can't be empty" substituting a fallback) then applies at
/// commit time and can no longer rewrite the text mid-edit, and one edit
/// produces one undo transaction instead of one per keystroke.
struct CommitOnBlurTextField: View {
    /// Stable identity of the edited slot (e.g. entity + field id). Editing
    /// state is dropped when the identity changes, so switching the selected
    /// entity mid-edit can't commit one entity's draft onto another.
    let identity: String
    let text: Binding<String>
    var size: TextField.Size = .regular
    var mixedValueLabel: String? = nil
    @State private var draftChanged = false

    @State private var draft: String = ""
    @State private var editingIdentity: String? = nil

    private var isEditing: Bool { editingIdentity == identity }

    var body: some View {
        let fieldBinding = Binding<String>(
            get: { isEditing ? draft : (mixedValueLabel == nil ? text.wrappedValue : "") },
            set: { next in
                // Self-arming: the first keystroke after a Return-commit (focus
                // retained, editing cleared) re-enters draft mode.
                if editingIdentity != identity { editingIdentity = identity }
                if draft != next { draft = next }
                draftChanged = true
            }
        )
        TextField(mixedValueLabel ?? "", text: fieldBinding,
                  size: size,
                  onSubmit: { commit() },
                  onFocus: {
                      let initial = mixedValueLabel == nil ? text.wrappedValue : ""
                      if draft != initial { draft = initial }
                      draftChanged = false
                      if editingIdentity != identity { editingIdentity = identity }
                  },
                  onBlur: { commit() })
    }

    private func commit() {
        guard isEditing else { return }
        editingIdentity = nil
        guard draftChanged else { return }
        draftChanged = false
        if mixedValueLabel != nil || text.wrappedValue != draft {
            text.wrappedValue = draft
        }
    }
}
