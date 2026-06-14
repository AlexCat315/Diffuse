import Foundation

public enum RenderPassKind: String, Sendable, CaseIterable {
    case depthPrepass
    case shadowPass
    case skybox
    case basePass
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

    /// Passes whose output is a pure function of the opaque scene inputs
    /// (geometry, lights, camera, settings) — i.e. everything before the
    /// transparent `particles` overlay. The opaque-render cache may skip these
    /// and reuse a snapshot when those inputs are unchanged.
    public static let opaquePasses: Set<RenderPassKind> = [
        .depthPrepass, .shadowPass, .skybox, .basePass,
        .outline, .inkPaperPost, .ssao, .ssr, .taa
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

        switch settings.stage {
            case .r0RainbowTriangle, .r1MeshCamera:
                passes.append(.basePass)
                appendStylizedPassesIfNeeded(settings: settings, passes: &passes)

            case .r2MultiObjectDepth:
                passes.append(contentsOf: [.depthPrepass, .basePass])
                appendStylizedPassesIfNeeded(settings: settings, passes: &passes)

            case .r3ViewportInterop:
                passes.append(contentsOf: [.depthPrepass, .basePass])
                appendStylizedPassesIfNeeded(settings: settings, passes: &passes)
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r4LightingPBRShadow:
                passes.append(.depthPrepass)
                if settings.shadowSettings.enabled && settings.shadowSettings.maxShadowedDirectionalLights > 0 {
                    passes.append(.shadowPass)
                }
                passes.append(contentsOf: [.skybox, .basePass])
                appendStylizedPassesIfNeeded(settings: settings, passes: &passes)
                passes.append(.tonemap)
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r5PostProcess:
                passes.append(.depthPrepass)
                if settings.shadowSettings.enabled && settings.shadowSettings.maxShadowedDirectionalLights > 0 {
                    passes.append(.shadowPass)
                }
                passes.append(contentsOf: [.skybox, .basePass])
                appendStylizedPassesIfNeeded(settings: settings, passes: &passes)
                if settings.enableSSAO {
                    passes.append(.ssao)
                }
                if settings.enableSSR {
                    passes.append(.ssr)
                }
                if settings.enableTAA {
                    passes.append(.taa)
                }
                if settings.enableBloom {
                    passes.append(.bloom)
                }
                passes.append(.tonemap)
                if settings.enableFXAA {
                    passes.append(.fxaa)
                }
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }
        }

        // Transparent billboard particles composite after every opaque and
        // opaque-screen-space pass (so they sit on the lit, AO'd, reflected
        // image) but before bloom/tonemap. This also marks the "lit opaque"
        // boundary that the opaque-render cache snapshots: everything up to
        // (and excluding) particles is a pure function of the opaque inputs.
        if let lastOpaque = passes.lastIndex(where: { RenderPassKind.opaquePasses.contains($0) }) {
            passes.insert(.particles, at: passes.index(after: lastOpaque))
        }

        return RenderFramePlan(passes: passes)
    }

    private static func appendStylizedPassesIfNeeded(settings: RenderSettings,
                                                     passes: inout [RenderPassKind]) {
        if settings.enableStylizedCharacterShading {
            passes.append(.outline)
            passes.append(.inkPaperPost)
        }
    }
}
