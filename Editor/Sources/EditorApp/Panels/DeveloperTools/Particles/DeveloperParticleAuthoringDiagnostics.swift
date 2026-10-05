import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

func makeDeveloperParticleEmitterLabels(roots: [EditorSceneNode]) -> [UInt64: DeveloperParticleEmitterLabel] {
    var labels: [UInt64: DeveloperParticleEmitterLabel] = [:]

    func visit(_ node: EditorSceneNode, parentPath: String?) {
        let path = parentPath.map { "\($0) / \(node.name)" } ?? node.name
        labels[node.id] = DeveloperParticleEmitterLabel(
            entityID: node.id,
            name: node.name,
            kind: node.kind,
            path: path
        )
        for child in node.children {
            visit(child, parentPath: path)
        }
    }

    for root in roots {
        visit(root, parentPath: nil)
    }
    return labels
}

func makeDeveloperParticleAuthoringDiagnosticSummary(
    gpuPlan: ParticleGPUSimulationPlan?,
    moduleIssues: [ParticleModuleIssue]
) -> DeveloperParticleDiagnosticSummary {
    let sortedIssues = moduleIssues.sorted(by: developerParticleModuleIssuePrecedes)
    let errorCount = sortedIssues.filter { $0.severity == .error }.count
    let warningCount = sortedIssues.filter { $0.severity == .warning }.count
    let infoCount = sortedIssues.filter { $0.severity == .info }.count
    let issueDetails = developerParticleModuleIssueDetails(sortedIssues)
    let gpuDetails = developerParticleGPUPlanDetails(gpuPlan)

    if errorCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .critical,
            status: "Authoring blocked",
            primarySignal: "\(errorCount) module \(errorCount == 1 ? "error" : "errors")",
            recommendation: "Fix module errors before profiling runtime pressure; blocked GPU-required emitters cannot execute as authored.",
            details: issueDetails + gpuDetails
        )
    }

    if let gpuPlan, gpuPlan.status == .requiredButUnsupported {
        return DeveloperParticleDiagnosticSummary(
            severity: .critical,
            status: "GPU simulation blocked",
            primarySignal: "Unsupported: \(developerParticleGPUUnsupportedReasonList(gpuPlan.unsupportedReasons))",
            recommendation: "Remove unsupported modules or switch the backend to GPU If Supported/CPU before relying on this effect.",
            details: gpuDetails
        )
    }

    if warningCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .warning,
            status: "Authoring warnings",
            primarySignal: "\(warningCount) module \(warningCount == 1 ? "warning" : "warnings")",
            recommendation: "Resolve warnings before chasing frame-time regressions; they often explain CPU fallback or clamped behavior.",
            details: issueDetails + gpuDetails
        )
    }

    if let gpuPlan {
        switch gpuPlan.status {
        case .disabled:
            return DeveloperParticleDiagnosticSummary(
                severity: .nominal,
                status: "CPU simulation selected",
                primarySignal: "Backend CPU",
                recommendation: "Keep CPU for low-volume emitters; move high-volume compatible effects to GPU If Supported.",
                details: gpuDetails
            )
        case .supported:
            return DeveloperParticleDiagnosticSummary(
                severity: .nominal,
                status: "GPU simulation ready",
                primarySignal: "Dispatch \(gpuPlan.dispatchWorkgroups)x\(gpuPlan.workgroupSize) for \(gpuPlan.particleCapacity) capacity",
                recommendation: "Track GPU workgroup split, sort padding, and readback drops as effect complexity grows.",
                details: gpuDetails
            )
        case .fallbackToCPU:
            return DeveloperParticleDiagnosticSummary(
                severity: .warning,
                status: "GPU fallback to CPU",
                primarySignal: "Unsupported: \(developerParticleGPUUnsupportedReasonList(gpuPlan.unsupportedReasons))",
                recommendation: "Remove unsupported features from this emitter or accept CPU simulation for this effect.",
                details: gpuDetails
            )
        case .requiredButUnsupported:
            return DeveloperParticleDiagnosticSummary(
                severity: .critical,
                status: "GPU simulation blocked",
                primarySignal: "Unsupported: \(developerParticleGPUUnsupportedReasonList(gpuPlan.unsupportedReasons))",
                recommendation: "Remove unsupported modules or switch the backend to GPU If Supported/CPU before relying on this effect.",
                details: gpuDetails
            )
        }
    }

    if infoCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .info,
            status: "Authoring notes",
            primarySignal: "\(infoCount) module \(infoCount == 1 ? "note" : "notes")",
            recommendation: "Review module notes when tuning the selected particle emitter.",
            details: issueDetails
        )
    }

    return DeveloperParticleDiagnosticSummary(
        severity: .idle,
        status: "No selected particle emitter",
        primarySignal: "No GPU plan or module issues",
        recommendation: "Select a particle emitter to inspect authored backend and module health.",
        details: []
    )
}

func developerParticleGPUUnsupportedReasonList(_ reasons: [ParticleGPUSimulationUnsupportedReason]) -> String {
    guard !reasons.isEmpty else { return "none" }
    return reasons.map(developerParticleGPUUnsupportedReasonLabel).joined(separator: ", ")
}

func developerParticleGPUUnsupportedReasonLabel(_ reason: ParticleGPUSimulationUnsupportedReason) -> String {
    switch reason {
    case .backendCPU:
        return "CPU backend"
    case .noParticleCapacity:
        return "no capacity"
    case .eventSubEmitters:
        return "sub-emitters"
    case .distanceEmission:
        return "distance emission"
    case .noise:
        return "noise"
    case .forceFields:
        return "force fields"
    case .collisions:
        return "collisions"
    case .angularVelocity:
        return "angular velocity"
    }
}

private func developerParticleGPUPlanDetails(_ plan: ParticleGPUSimulationPlan?) -> [String] {
    guard let plan else { return [] }
    var details = [
        "GPU plan \(developerParticleGPUPlanStatusLabel(plan.status))",
        "Capacity \(plan.particleCapacity), dispatch \(plan.dispatchWorkgroups)x\(plan.workgroupSize)",
    ]
    if !plan.unsupportedReasons.isEmpty {
        details.append("Unsupported \(developerParticleGPUUnsupportedReasonList(plan.unsupportedReasons))")
    }
    return details
}

private func developerParticleGPUPlanStatusLabel(_ status: ParticleGPUSimulationPlanStatus) -> String {
    switch status {
    case .disabled:
        return "CPU"
    case .supported:
        return "Ready"
    case .fallbackToCPU:
        return "Fallback"
    case .requiredButUnsupported:
        return "Blocked"
    }
}

private func developerParticleModuleIssueDetails(_ issues: [ParticleModuleIssue],
                                                 limit: Int = 4) -> [String] {
    guard !issues.isEmpty else { return [] }
    let clippedLimit = max(0, limit)
    var details = issues.prefix(clippedLimit).map { issue in
        "\(issue.moduleID) [\(issue.severity.rawValue)]: \(issue.message)"
    }
    if issues.count > clippedLimit {
        details.append("\(issues.count - clippedLimit) more module issues")
    }
    return details
}

private func developerParticleModuleIssuePrecedes(_ lhs: ParticleModuleIssue,
                                                  _ rhs: ParticleModuleIssue) -> Bool {
    let lhsRank = developerParticleModuleIssueSeverityRank(lhs.severity)
    let rhsRank = developerParticleModuleIssueSeverityRank(rhs.severity)
    if lhsRank != rhsRank { return lhsRank > rhsRank }
    if lhs.moduleID != rhs.moduleID { return lhs.moduleID < rhs.moduleID }
    return lhs.code < rhs.code
}

private func developerParticleModuleIssueSeverityRank(_ severity: ParticleModuleIssueSeverity) -> Int {
    switch severity {
    case .error:
        return 3
    case .warning:
        return 2
    case .info:
        return 1
    }
}
