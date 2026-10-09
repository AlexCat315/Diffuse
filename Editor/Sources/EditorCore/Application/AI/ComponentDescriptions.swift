import AIRuntime
import SceneRuntime

extension EditorApplication {
    func makeComponentDescriptionProvider() -> Session.ComponentDescriptionProvider {
        { [weak self] typeID in
            await MainActor.run { self?.scene.componentDescriptions(typeID: typeID) ?? [] }
        }
    }
}
