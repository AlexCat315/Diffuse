import Foundation

public enum RenderPassKind: String, Sendable, CaseIterable {
    case depthPrepass
    case shadowPass
    case skybox
    case basePass
    case outline
    case ssao
    case ssr
    case taa
    case bloom
    case fxaa
    case tonemap
    case viewportResolve
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
                appendStylizedOutlineIfNeeded(settings: settings, passes: &passes)

            case .r2MultiObjectDepth:
                passes.append(contentsOf: [.depthPrepass, .basePass])
                appendStylizedOutlineIfNeeded(settings: settings, passes: &passes)

            case .r3ViewportInterop:
                passes.append(contentsOf: [.depthPrepass, .basePass])
                appendStylizedOutlineIfNeeded(settings: settings, passes: &passes)
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r4LightingPBRShadow:
                passes.append(.depthPrepass)
                if settings.enableShadows {
                    passes.append(.shadowPass)
                }
                passes.append(contentsOf: [.skybox, .basePass])
                appendStylizedOutlineIfNeeded(settings: settings, passes: &passes)
                passes.append(.tonemap)
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r5PostProcess:
                passes.append(.depthPrepass)
                if settings.enableShadows {
                    passes.append(.shadowPass)
                }
                passes.append(contentsOf: [.skybox, .basePass])
                appendStylizedOutlineIfNeeded(settings: settings, passes: &passes)
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

        return RenderFramePlan(passes: passes)
    }

    private static func appendStylizedOutlineIfNeeded(settings: RenderSettings,
                                                       passes: inout [RenderPassKind]) {
        if settings.enableStylizedCharacterShading {
            passes.append(.outline)
        }
    }
}
