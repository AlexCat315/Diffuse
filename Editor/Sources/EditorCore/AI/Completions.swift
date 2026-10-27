import AIRuntime
import Foundation
public import PluginRuntime

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
        let serviceID = "diffuse.ai.completion/v1"
        let providers = pluginSession.contributions.services.snapshot.values
        guard let package = providers.first(where: {
            ((try? $0.value.manifest.contributes.decode(PluginServiceContributionPoint.self)) ?? []).contains { $0.id == serviceID }
        }), let service = try package.value.manifest.contributes.decode(PluginServiceContributionPoint.self).first(where: { $0.id == serviceID }) else {
            throw EditorProjectToolError("Enable a plugin providing text completion, then configure its model.")
        }
        func invoke(_ request: [String: String]) async throws -> [String: Any] {
            try Task.checkCancellation()
            let json = try JSONSerialization.data(withJSONObject: request)
            let value = try await readEntryPoint(pluginID: package.value.manifest.id, entryPoint: service.entryPoint,
                event: "onService:" + serviceID, input: ["request": String(decoding: json, as: UTF8.self)])
            return (try JSONSerialization.jsonObject(with: value) as? [String: Any]) ?? [:]
        }
        let started = try await invoke(["operation": "start", "instructions": instructions, "prompt": prompt, "maxTokens": String(maxTokens ?? 8192)])
        guard let handle = started["handle"] as? String else { throw PluginCommandError.unavailable }
        do {
            while true {
                let result = try await invoke(["operation": "poll", "handle": handle])
                if let error = result["error"] as? String { throw EditorProjectToolError(error) }
                if result["done"] as? Bool == true { return result["text"] as? String ?? "" }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            let request = try JSONSerialization.data(withJSONObject: ["operation": "cancel", "handle": handle])
            _ = try? await readEntryPoint(pluginID: package.value.manifest.id, entryPoint: service.entryPoint,
                event: "onService:" + serviceID, input: ["request": String(decoding: request, as: UTF8.self)])
            throw error
        }
    }
}
