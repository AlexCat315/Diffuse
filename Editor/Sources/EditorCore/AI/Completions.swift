import AIRuntime
import Foundation

/// One-shot, tool-less completions the editor asks of the configured model.
extension EditorApplication {
    /// Drafts a commit message from the changes about to be committed: the
    /// staged changes, or every change when nothing is staged.
    @MainActor
    public func draftCommitMessage() async throws -> String {
        let versionControl = workstation.versionControl
        let snapshot = versionControl.snapshot
        let changes = snapshot.staged.isEmpty ? snapshot.unstaged : snapshot.staged
        guard !changes.isEmpty else { throw EditorProjectToolError("There are no changes to describe.") }
        var budget = 40_000
        var sections: [String] = []
        for change in changes.prefix(40) {
            let summary = "\(change.state.rawValue): \(change.path)"
            guard budget > 0 else { sections.append(summary); continue }
            let diff = String(await versionControl.diff(change).prefix(min(budget, 8_000)))
            budget -= diff.count
            sections.append(summary + (diff.isEmpty ? "" : "\n" + diff))
        }
        let recent = snapshot.history.prefix(8).map(\.summary).joined(separator: "\n")
        let message = try await completeText(instructions: """
            Write a commit message for the changes below. Use a concise imperative subject line \
            of at most 72 characters, then a blank line and a short body only when the change needs \
            explanation. Follow the style of the recent messages when they share a convention. \
            Reply with the commit message only.
            """, prompt: "Recent commit messages:\n\(recent.isEmpty ? "(none)" : recent)\n\nChanges:\n\(sections.joined(separator: "\n\n"))",
            maxTokens: 400)
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
    }

    @MainActor
    func completeText(instructions: String, prompt: String, maxTokens: Int? = nil) async throws -> String {
        await pendingAISetupTask?.value
        guard let session else {
            throw EditorProjectToolError(store.state.assistant.aiSettings.isEnabled
                ? "The configured AI provider has no usable credential."
                : "No AI provider configured. Choose one in Settings.")
        }
        return try await session.complete(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
    }
}
