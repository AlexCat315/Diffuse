import Foundation

/// Unified input to the Session, covering all authoring modalities.
public enum Signal: Sendable {
    case naturalLanguage(text: String, locale: String)
    case selectionChanged(entityRefs: [String])
    case worldChanged(editSummary: String, revision: UInt64)
    case userCorrection(proposalID: String,
                        acceptedStepIDs: [String],
                        rejectedStepIDs: [String])

    public var kind: String {
        switch self {
        case .naturalLanguage:  return "naturalLanguage"
        case .selectionChanged: return "selectionChanged"
        case .worldChanged:     return "worldChanged"
        case .userCorrection:   return "userCorrection"
        }
    }
}
