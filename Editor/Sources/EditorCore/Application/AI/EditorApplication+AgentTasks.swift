import AIRuntime
import Foundation

extension EditorApplication {
    func updateAgentTask(_ phase: EditorAgentTaskPhase, summary: String = "") {
        agentTaskService.transition(to: phase, summary: summary)
        store.dispatch(.setAgentTasks(agentTaskService.tasks))
    }

    func validateAgentTaskTarget(_ target: EditorAgentTaskTarget) throws {
        guard isSceneAuthoringEnabled else {
            throw EditorProjectToolError("Stop simulation before applying an authoring task.")
        }
        guard target.matches(documentID: store.state.document.identity, sceneRevision: store.sceneRevision) else {
            throw EditorProjectToolError("The task's scene changed. Submit a new task against the current version.")
        }
    }

    func makeAgentWorkflowScope(target: EditorAgentTaskTarget) -> SessionWorkflowScope {
        let profile = target.workspace.profile
        return SessionWorkflowScope {
            $0.context = Self.workflowContext(for: target.workspace, scriptEntries: scene.scriptCatalogEntries)
            // Plugins still require their existing explicit authority binding.
            let pluginIDs = pluginCapabilityExecutor?.registry.allVerbs().filter {
                pluginCapabilityExecutor?.registry.descriptor(for: $0)?.source.kind == .plugin
            } ?? []
            $0.allowedCapabilityIDs = profile.capabilityIDs.union(pluginIDs)
            $0.allowedProjectToolNames = profile.projectToolNames
            $0.selectedEntityRefs = target.selectedEntityIDs.sorted().map { "scene:\($0)" }
        }
    }

    /// Replacing a scene invalidates requests even if the new scene happens to
    /// have the same numeric revision as the old one.
    func beginAgentSceneDocument() {
        if store.pendingConfirmationRequest != nil { skipPendingConfirmation() }
        cancelActiveAIRequest()
        agentExecution.assistantMessageID = nil
        agentExecution.confirmationTargetEntityIDs.removeAll()
        store.dispatch(.setPendingConfirmationRequest(nil))
        store.dispatch(.beginSceneDocument)
    }

    public func cancelAgentTask() {
        guard agentExecution.requestID != nil else { return }
        cancelActiveAIRequest()
        if let session { Task { await session.cancelActiveRun() } }
    }
}
