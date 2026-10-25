internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// The review of a package opened with `--review-plugin`, over the editor
/// window, so a plugin author can approve it and use it in one launch. It is
/// the same review Settings shows; nothing is enabled until Enable is chosen.
struct LaunchPluginReview: View {
    let app: EditorApplication
    let management: EditorPluginManagementState

    var body: some View {
        if let candidate = management.candidate {
            ModalBarrier {
                PluginReviewCard(summary: candidate, isBusy: management.phase == .enabling,
                                 isAlreadyEnabled: management.installed.contains { $0.id == candidate.id && $0.lifecycle.isEnabled },
                                 onEnable: { Task { @MainActor in await app.authorizeAndEnableInspectedPlugin() } },
                                 onCancel: { Task { @MainActor in app.cancelPluginApproval() } })
                    .padding(20)
                    .frame(width: 520)
                    .background(.surfaceFloating)
                    .cornerRadius(14)
                    .border(.border, width: 1)
                    .debugName("launch-plugin-review")
            }
        }
    }
}
