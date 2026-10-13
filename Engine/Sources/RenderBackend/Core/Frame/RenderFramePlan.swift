import Foundation

public enum RenderPassKind: String, Sendable, CaseIterable {
    case depthPrepass
    case shadowPass
    case skybox
    case basePass
    case editorGrid
    case transparentMeshes
    case particles
    case outline
    case inkPaperPost
    case ssao
    case ssr
    case taa
    case bloom
    case fxaa
    case tonemap
    case viewportResolve
    /// Dynamic HUD overlay, recorded after scene post-processing.
    case inGameUI

    /// Passes whose output is a pure function of the opaque scene inputs
    /// (geometry, lights, camera, settings) — i.e. everything before the
    /// transparent `particles` overlay. The opaque-render cache may skip these
    /// and reuse a snapshot when those inputs are unchanged.
    public static let opaquePasses: Set<RenderPassKind> = [
        .depthPrepass, .shadowPass, .skybox, .basePass,
        .outline, .inkPaperPost, .ssao, .ssr, .taa, .editorGrid
    ]
}

public struct RenderFramePlan: Sendable, Equatable {
    public var passes: [RenderPassKind]

    public init(passes: [RenderPassKind]) {
        self.passes = passes
    }
}

enum RenderFramePlanner {
    static func makePlan(settings: RenderSettings) -> RenderFramePlan {
        var passes: [RenderPassKind] = []

        if settings.shading.depthPrepass {
            passes.append(.depthPrepass)
        }
        if settings.shadows.enabled && settings.shadows.maxShadowedDirectionalLights > 0 {
            passes.append(.shadowPass)
        }
        if settings.shading.pbr {
            passes.append(.skybox)
        }
        passes.append(.basePass)
        appendStylizedPassesIfNeeded(settings: settings, passes: &passes)
        if settings.postProcessing.ssao {
            passes.append(.ssao)
        }
        if settings.postProcessing.ssr {
            passes.append(.ssr)
        }
        if settings.postProcessing.taa {
            passes.append(.taa)
        }
        if settings.postProcessing.bloom {
            passes.append(.bloom)
        }
        if settings.shading.pbr {
            passes.append(.tonemap)
        }
        if settings.postProcessing.fxaa {
            passes.append(.fxaa)
        }
        if settings.viewport.offscreen {
            passes.append(.viewportResolve)
        }

        // Reference lines use scene depth, without contributing to depth or
        // screen-space lighting. Draw before TAA so its history and current
        // image both contain the grid, then include it in the opaque snapshot.
        if settings.viewport.gridEnabled,
           let lastOpaque = passes.lastIndex(where: { RenderPassKind.opaquePasses.contains($0) }) {
            passes.insert(.editorGrid, at: passes.firstIndex(of: .taa) ?? passes.index(after: lastOpaque))
        }

        // Transparent billboard particles composite after every opaque and
        // opaque-screen-space pass (so they sit on the lit, AO'd, reflected
        // image) but before bloom/tonemap. This also marks the "lit opaque"
        // boundary that the opaque-render cache snapshots: everything up to
        // (and excluding) particles is a pure function of the opaque inputs.
        if let lastOpaque = passes.lastIndex(where: { RenderPassKind.opaquePasses.contains($0) }) {
            passes.insert(contentsOf: [.transparentMeshes, .particles], at: passes.index(after: lastOpaque))
        }

        return RenderFramePlan(passes: passes)
    }

    /// Progressive refinement: while the opaque scene is moving (camera or
    /// geometry changing frame-to-frame), drop the most expensive screen-space
    /// pass (SSR) so interaction stays responsive. Full quality returns the
    /// moment the scene settles. Stacks with the editor's interaction
    /// render-scale downscale.
    static func motionRefinedPasses(_ passes: [RenderPassKind], opaqueMoving: Bool) -> [RenderPassKind] {
        guard opaqueMoving else { return passes }
        return passes.filter { $0 != .ssr }
    }

    private static func appendStylizedPassesIfNeeded(settings: RenderSettings,
                                                     passes: inout [RenderPassKind]) {
        if settings.stylization.enabled {
            passes.append(.outline)
            passes.append(.inkPaperPost)
        }
    }
}
