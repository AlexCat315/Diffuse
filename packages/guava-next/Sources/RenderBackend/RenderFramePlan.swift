import Foundation

public enum RenderPassKind: String, Sendable, CaseIterable {
    case depthPrepass
    case shadowPass
    case basePass
    case viewportResolve
    case ssao
    case bloom
    case fxaa
    case tonemap
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
                passes.append(.basePass)
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }

            case .r5PostProcess:
                passes.append(.depthPrepass)
                if settings.enableShadows {
                    passes.append(.shadowPass)
                }
                passes.append(.basePass)
                if settings.enableOffscreenViewport {
                    passes.append(.viewportResolve)
                }
                if settings.enableSSAO {
                    passes.append(.ssao)
                }
                if settings.enableBloom {
                    passes.append(.bloom)
                }
                if settings.enableFXAA {
                    passes.append(.fxaa)
                }
                passes.append(.tonemap)
        }

        return RenderFramePlan(passes: passes)
    }
}
