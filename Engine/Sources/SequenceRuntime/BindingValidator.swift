import Foundation

public enum BindingValidator {
    public enum RenderValidationResult: Sendable, Equatable {
        case ok
        case blocked([String])
    }

    /// Validates all bindings across all shots are `bound`. Returns `.blocked` with the
    /// IDs of any unresolved, stale, or conflicting bindings; required before render submission.
    public static func validateForRender(_ document: SequenceDocument) -> RenderValidationResult {
        var blockedIDs: [String] = []
        for shot in document.shots {
            collectBlockedBindings(shot.cameraBinding, into: &blockedIDs)
            for track in shot.tracks {
                for clip in track.clips {
                    for binding in clip.bindings {
                        collectBlockedBindings(binding, into: &blockedIDs)
                    }
                }
            }
        }
        return blockedIDs.isEmpty ? .ok : .blocked(blockedIDs)
    }

    /// Resolves a single binding at evaluation time. Returns `nil` when the binding should
    /// be skipped (`.skip` fallback or `.proxy` which is not yet implemented), or throws
    /// for `.error` fallback with a stale/conflict status.
    public static func resolvedTarget(for binding: Binding) throws -> SceneTargetReference? {
        switch binding.resolutionStatus {
        case .bound:
            return binding.resolvedTarget
        case .unbound, .stale, .conflict:
            switch binding.fallbackStrategy {
            case .skip:
                return nil
            case .proxy:
                return nil
            case .error:
                throw BindingError(bindingID: binding.id,
                                   status: binding.resolutionStatus)
            }
        }
    }

    private static func collectBlockedBindings(_ binding: Binding, into ids: inout [String]) {
        switch binding.resolutionStatus {
        case .bound:
            break
        case .unbound, .stale, .conflict:
            ids.append(binding.id)
        }
    }
}

public struct BindingError: Error, CustomStringConvertible, Sendable {
    public var bindingID: String
    public var status: BindingResolutionStatus

    public init(bindingID: String, status: BindingResolutionStatus) {
        self.bindingID = bindingID
        self.status = status
    }

    public var description: String {
        "Binding '\(bindingID)' is \(status.rawValue); cannot resolve target for render."
    }
}
