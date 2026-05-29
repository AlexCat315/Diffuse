import Foundation

/// Exponential-backoff retry policy for transient inference failures (rate limits, 5xx,
/// dropped connections). Pure value type so the backoff schedule is unit-testable without
/// touching the network.
public struct RetryPolicy: Sendable, Equatable {
    /// Number of retries *after* the first attempt (total attempts = maxRetries + 1).
    public var maxRetries: Int
    /// Backoff for the first retry, in seconds. Doubles each subsequent attempt.
    public var baseDelay: TimeInterval
    /// Upper bound on any single backoff, in seconds.
    public var maxDelay: TimeInterval
    /// Fractional jitter applied to the computed delay (0…1), spreading retries to avoid
    /// thundering-herd stampedes against the endpoint.
    public var jitter: Double

    public init(maxRetries: Int = 3,
                baseDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 20,
                jitter: Double = 0.2) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(max(0, jitter), 1)
    }

    /// Default policy: 3 retries, 0.5s base, capped at 20s, ±20% jitter.
    public static let `default` = RetryPolicy()
    /// Disables retrying entirely.
    public static let none = RetryPolicy(maxRetries: 0)

    /// HTTP status codes worth retrying: request timeout, rate limit, and 5xx server errors.
    public static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Backoff delay before the retry following zero-based `attempt`. An explicit `retryAfter`
    /// (from a `Retry-After` header) wins, capped at `maxDelay`. `randomUnit` (0…1) injects
    /// jitter deterministically so tests can pin the result.
    public func delay(forAttempt attempt: Int,
                      retryAfter: TimeInterval? = nil,
                      randomUnit: Double = 0.5) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, maxDelay) }
        let exponential = baseDelay * pow(2, Double(max(0, attempt)))
        let capped = min(exponential, maxDelay)
        // Map randomUnit 0…1 to a ±jitter multiplier around the capped delay.
        let spread = capped * jitter * (randomUnit * 2 - 1)
        return max(0, capped + spread)
    }
}
