import Foundation

public enum RenderPassKind: String, Sendable, CaseIterable {
    case depthPrepass
    case shadowPass
    case skybox
    case basePass
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

            case .r2MultiObjectDepth:
                passes.append(contentsOf: [.depthPrepass, .basePass])

            case .r3ViewportInterop:
                passes.append(contentsOf: [.depthPrepass, .basePass])
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r4LightingPBRShadow:
                passes.append(.depthPrepass)
                if settings.enableShadows {
                    passes.append(.shadowPass)
                }
                passes.append(contentsOf: [.skybox, .basePass, .tonemap])
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r5PostProcess:
                passes.append(.depthPrepass)
                if settings.enableShadows {
                    passes.append(.shadowPass)
                }
                passes.append(contentsOf: [.skybox, .basePass])
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
}
