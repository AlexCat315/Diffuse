import Foundation

public struct CacheValidationResult: Sendable, Equatable {
    public var isValid: Bool
    public var isStale: Bool
    public var reason: String?

    public static let valid = CacheValidationResult(isValid: true, isStale: false, reason: nil)

    public init(isValid: Bool, isStale: Bool, reason: String?) {
        self.isValid = isValid
        self.isStale = isStale
        self.reason = reason
    }
}

public enum CacheValidator {
    /// Returns whether `cache` can be used for evaluation given the shot's current revision.
    ///
    /// - strict: the cache source revision must exactly match `currentRevision.id`. Any mismatch
    ///   returns `isValid = false`; the evaluator must re-simulate.
    /// - tolerant: a stale cache is still readable (`isValid = true`) but `isStale` is set so
    ///   diagnostics can surface it. Never use tolerant mode for a final render submission.
    public static func validate(_ cache: SequenceCache,
                                currentRevision: SequenceRevision) -> CacheValidationResult {
        let revisionMatches = cache.sourceRevision.id == currentRevision.id
        switch cache.invalidationPolicy {
        case .strict:
            if revisionMatches {
                return .valid
            }
            return CacheValidationResult(
                isValid: false,
                isStale: true,
                reason: "strict cache '\(cache.id)' source revision '\(cache.sourceRevision.id)' " +
                        "does not match current revision '\(currentRevision.id)'"
            )
        case .tolerant:
            return CacheValidationResult(
                isValid: true,
                isStale: !revisionMatches,
                reason: revisionMatches ? nil :
                    "tolerant cache '\(cache.id)' is stale but still readable"
            )
        }
    }

    /// Returns the first valid cache entry for `shotID` that covers `frame` and matches the
    /// current revision, using the cache's own `hitStrategy`.
    public static func bestCache(from caches: [SequenceCache],
                                 shotID: String,
                                 frame: Int64,
                                 currentRevision: SequenceRevision) -> SequenceCache? {
        let candidates = caches.filter { cache in
            cache.shotID == shotID &&
            cache.range.contains(frame) &&
            validate(cache, currentRevision: currentRevision).isValid
        }
        return candidates.sorted { $0.range.contains(frame) && !$1.range.contains(frame) }.first
    }
}
