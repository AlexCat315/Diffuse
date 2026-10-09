import Foundation

/// Unified input to the Session, covering all authoring modalities.
public enum Signal: Sendable {
    case naturalLanguage(text: String, locale: String)
    case selectionChanged(entityRefs: [String])
    case worldChanged(editSummary: String, revision: UInt64)
    case userCorrection(proposalID: String,
                        acceptedStepIDs: [String],
                        rejectedStepIDs: [String])
    /// An image supplied as a reference for a scene entity or for scene creation.
    /// Perception results should already be applied to the WorldView before this signal is
    /// processed — Session uses the inferred properties in the entity index to produce a plan.
    case referenceImage(url: URL, entityRef: String?)

    public var kind: String {
        switch self {
        case .naturalLanguage:  return "naturalLanguage"
        case .selectionChanged: return "selectionChanged"
        case .worldChanged:     return "worldChanged"
        case .userCorrection:   return "userCorrection"
        case .referenceImage:   return "referenceImage"
        }
    }
}
