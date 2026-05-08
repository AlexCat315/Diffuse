import Foundation

/// Unified input to the Session, covering all authoring modalities.
public enum Signal: Sendable {
    case naturalLanguage(text: String, locale: String)
    case selectionChanged(entityRefs: [String])
    case worldChanged(editSummary: String, revision: UInt64)
    case userCorrection(proposalID: String,
                        acceptedStepIDs: [String],
                        rejectedStepIDs: [String])
}
