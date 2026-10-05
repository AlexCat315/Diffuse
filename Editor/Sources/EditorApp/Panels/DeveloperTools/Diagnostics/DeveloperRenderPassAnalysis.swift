import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperRenderPassInspection: Equatable {
    var name: String
    var drawCallCount: Int
    var encodeNS: UInt64
    var signal: String
    var recommendation: String
}

func makeDeveloperRenderPassBreakdown(renderStats: RenderFrameStats) -> [DeveloperRenderPassInspection] {
    var passNames: [RenderPassKind] = []
    for pass in renderStats.activePasses {
        if !passNames.contains(pass) {
            passNames.append(pass)
        }
    }
    for pass in renderStats.passDrawCallCounts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        if !passNames.contains(pass) {
            passNames.append(pass)
        }
    }
    for pass in renderStats.passEncodeNS.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        if !passNames.contains(pass) {
            passNames.append(pass)
        }
    }

    return passNames.map { pass in
        let draws = renderStats.passDrawCallCounts[pass] ?? 0
        let encodeNS = renderStats.passEncodeNS[pass] ?? 0
        return DeveloperRenderPassInspection(
            name: pass.rawValue,
            drawCallCount: draws,
            encodeNS: encodeNS,
            signal: developerRenderPassSignal(pass: pass,
                                              draws: draws,
                                              encodeNS: encodeNS,
                                              renderStats: renderStats),
            recommendation: developerRenderPassRecommendation(pass: pass,
                                                              draws: draws,
                                                              encodeNS: encodeNS,
                                                              renderStats: renderStats)
        )
    }
    .sorted {
        if $0.encodeNS != $1.encodeNS { return $0.encodeNS > $1.encodeNS }
        if $0.drawCallCount != $1.drawCallCount { return $0.drawCallCount > $1.drawCallCount }
        return $0.name < $1.name
    }
}

private func developerRenderPassSignal(pass: RenderPassKind,
                                       draws: Int,
                                       encodeNS: UInt64,
                                       renderStats: RenderFrameStats) -> String {
    if encodeNS > 0 {
        return "\(formatNs(encodeNS)) encode, \(draws) draws"
    }
    if draws > 0 {
        return "\(draws) draws"
    }
    if pass == .particles && renderStats.gpuParticleRenderInstanceCount > 0 {
        return "\(renderStats.gpuParticleRenderInstanceCount) GPU particle instances"
    }
    return "No measured work"
}

private func developerRenderPassRecommendation(pass: RenderPassKind,
                                               draws: Int,
                                               encodeNS: UInt64,
                                               renderStats: RenderFrameStats) -> String {
    if encodeNS > 16_700_000 {
        return "Inspect resources and draw submission in this pass before changing global viewport quality."
    }
    if pass == .particles && renderStats.gpuParticleSortPaddedItemCount > renderStats.gpuParticleSortItemCount {
        return "Check particle sort padding, GPU work split, and render-budget skips in the Particles tool."
    }
    if draws > 1_000 {
        return "Look for batching, instancing, or culling opportunities tied to this pass."
    }
    if draws == 0 {
        return "The pass is active but has no submitted draws; verify whether it is required for this frame."
    }
    return "Pass work is measurable; compare it against adjacent passes before tuning content."
}
