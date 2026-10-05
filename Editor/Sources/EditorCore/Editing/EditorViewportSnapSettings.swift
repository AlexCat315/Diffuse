import Foundation

/// Per-project editor preferences, stored separately from authored scene data.
public struct EditorViewportSnapSettings: Codable, Sendable, Equatable {
    public var translateEnabled: Bool
    public var rotateEnabled: Bool
    public var scaleEnabled: Bool
    public var translateStep: Float
    public var rotateStepDegrees: Float
    public var scaleStep: Float

    public init(state: EditorState) {
        translateEnabled = state.translateSnapEnabled
        rotateEnabled = state.rotateSnapEnabled
        scaleEnabled = state.scaleSnapEnabled
        translateStep = EditorState.sanitizedTranslateSnapStep(state.translateSnapStep)
        rotateStepDegrees = EditorState.sanitizedRotateSnapStep(state.rotateSnapStepDegrees)
        scaleStep = EditorState.sanitizedScaleSnapStep(state.scaleSnapStep)
    }

    func restore(in store: EditorStore) {
        store.dispatch(.setTranslateSnapEnabled(translateEnabled))
        store.dispatch(.setRotateSnapEnabled(rotateEnabled))
        store.dispatch(.setScaleSnapEnabled(scaleEnabled))
        store.dispatch(.setTranslateSnapStep(translateStep))
        store.dispatch(.setRotateSnapStepDegrees(rotateStepDegrees))
        store.dispatch(.setScaleSnapStep(scaleStep))
    }
}
