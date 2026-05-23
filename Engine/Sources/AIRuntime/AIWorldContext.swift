import Foundation
import IntentRuntime

/// Local semantic state shared by AI providers and local perception workers.
///
/// This keeps Guava's AI-visible world available even when no remote text
/// provider is configured. Remote `Session` instances can be seeded from it.
public actor AIWorldContext {
    private var worldView: WorldView

    public init(worldView: WorldView = WorldView()) {
        self.worldView = worldView
    }

    public func observe(snapshot: SceneSemanticSnapshot) {
        worldView.apply(snapshot: snapshot)
    }

    public func observe(event: WorldEvent) {
        worldView.apply(event: event)
    }

    public func observe(events: [WorldEvent]) {
        for event in events {
            worldView.apply(event: event)
        }
    }

    public func replaceWorldView(_ worldView: WorldView) {
        self.worldView = worldView
    }

    public func snapshot() -> WorldView {
        worldView
    }

    public func entityRecord(ref: String) -> WorldEntityRecord? {
        worldView.entityIndex[ref]
    }
}
