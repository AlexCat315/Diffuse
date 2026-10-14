import Foundation
import GuavaUIAgent

final class EditorDiagnosticSession {
    var ui: UIDiagnostics?
    func close() {
        let current = ui
        ui = nil
        if Thread.isMainThread { MainActor.assumeIsolated { current?.resetCaptures() } }
        else { Task { @MainActor in current?.resetCaptures() } }
    }
}

extension EditorApplication {
    /// The application host owns runtime queries. Editor adds only its domain data.
    @MainActor
    public func setUIDiagnostics(_ diagnostics: UIDiagnostics?) {
        if diagnosticSession.ui !== diagnostics { diagnosticSession.ui?.resetCaptures() }
        diagnosticSession.ui = diagnostics
    }

    @MainActor
    func executeDiagnosticTool(name: String, input: Data) async throws -> Data? {
        guard UIDiagnosticTools.tools.contains(where: { $0.name == name }) else { return nil }
        if name == "get_diagnostics" {
            let args = (try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            let limit = args["limit"] as? Int ?? 50
            let report = diagnosticReport(limit: limit)
            return try JSONEncoder().encode(report)
        }
        // Task guides remain available in headless sessions.
        if name == "list_skills" {
            let metadata = try UIDiagnosticTools.skills().skills.map { ["name": $0.name, "description": $0.description] }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "data": metadata])
        }
        if name == "read_skill" {
            let args = (try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            let skill = try UIDiagnosticTools.skills().read(name: args["name"] as? String ?? "")
            return try JSONEncoder().encode(SkillResponse(data: skill))
        }
        guard let diagnostics = diagnosticSession.ui else {
            throw EditorProjectToolError("UI diagnostics are unavailable: this editor has no attached graphical UI session.")
        }
        let result = try await diagnostics.execute(name: name, input: input)
        guard isActive else { throw CancellationError() }
        return result.json
    }

    @MainActor
    private func diagnosticReport(limit: Int) -> EditorDiagnosticReport {
        let selected = store.state.selection.selectedEntityID
        let render = currentRenderStats()
        let particle = currentParticleFrameStats()
        let events = currentParticleSimulationEventApplyReport()
        let issues = makeDeveloperWorkbenchIssues(frameStats: currentFrameStats(),
            frameHistory: store.state.timing.frameStatsHistory,
            renderStats: render,
            particleSummary: makeDeveloperParticleDiagnosticSummary(stats: particle, eventReport: events,
                scalability: currentParticleScalabilityState(), renderSummary: currentRenderScene().particleSummary,
                renderStats: render),
            particleAuthoringSummary: selected.map { id in makeDeveloperParticleAuthoringDiagnosticSummary(
                gpuPlan: scene.currentParticleGPUSimulationPlan(for: id),
                moduleIssues: scene.currentParticleModuleValidationIssues(for: id)) },
            particleHotspots: makeDeveloperParticleEmitterHotspots(stats: particle, eventReport: events),
            selectedEntityID: selected, consoleEntries: store.state.output.consoleEntries)
        return EditorDiagnosticReport(sceneRevision: scene.revision,
            uiAvailable: diagnosticSession.ui != nil,
            frameSampleCount: store.state.timing.frameStatsHistory.count,
            renderFrameIndex: render.frameIndex,
            issues: Array(issues.prefix(min(100, max(1, limit)))), totalIssueCount: issues.count,
            frameTrend: makeDeveloperFrameTrendSummary(history: store.state.timing.frameStatsHistory),
            renderPasses: Array(makeDeveloperRenderPassBreakdown(renderStats: render).prefix(100)))
    }
}

private struct SkillResponse: Encodable {
    let ok = true
    let data: AgentSkill
}

private struct EditorDiagnosticReport: Encodable {
    let ok = true
    let sceneRevision: UInt64
    let uiAvailable: Bool
    let frameSampleCount: Int
    let renderFrameIndex: Int
    let issues: [DeveloperDiagnosticIssue]
    let totalIssueCount: Int
    let frameTrend: DeveloperFrameTrendSummary?
    let renderPasses: [DeveloperRenderPassInspection]
}
