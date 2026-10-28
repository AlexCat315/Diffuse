@testable import EditorUI
import EditorCore

extension ViewportDisplayOptions {
    static var testDefaults: Self {
        .init(state: .init(shading: .lit,grid: true,shadows: true,renderScalePercent: 100,
                           interactionDownscale: false,realtime: true,physics: nil),
              actions: .init(selectShading: { _ in },toggleGrid: {},toggleShadows: {},selectRenderScale: { _ in },
                             toggleInteractionDownscale: {},toggleRealtime: {},setPhysicsOptions: { _ in },setPhysicsScope: { _ in }))
    }
}
