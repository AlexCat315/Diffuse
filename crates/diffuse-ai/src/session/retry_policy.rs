//! Ported from `Engine/Sources/AIRuntime/Session/RetryPolicy.swift`.

/// Exponential-backoff retry policy for transient inference failures (rate
/// limits, 5xx, dropped connections). Pure value type so the backoff schedule
/// stays unit-testable without touching the network.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetryPolicy {
    /// Number of retries *after* the first attempt (total attempts =
    /// `max_retries + 1`).
    pub max_retries: usize,
    /// Backoff for the first retry, in seconds. Doubles each subsequent attempt.
    pub base_delay: f64,
    /// Upper bound on any single backoff, in seconds.
    pub max_delay: f64,
    /// Fractional jitter applied to the computed delay (0…1), spreading
    /// retries to avoid thundering-herd stampedes against the endpoint.
    pub jitter: f64,
}

impl RetryPolicy {
    pub fn new(max_retries: usize, base_delay: f64, max_delay: f64, jitter: f64) -> Self {
        Self {
            max_retries,
            base_delay: base_delay.max(0.0),
            max_delay: max_delay.max(0.0),
            jitter: jitter.clamp(0.0, 1.0),
        }
    }

    /// Default policy: 3 retries, 0.5s base, capped at 20s, ±20% jitter.
    pub fn with_defaults() -> Self {
        Self::new(3, 0.5, 20.0, 0.2)
    }

    /// Disables retrying entirely.
    pub fn none() -> Self {
        Self::new(0, 0.5, 20.0, 0.2)
    }

    /// HTTP status codes worth retrying: request timeout, rate limit, and 5xx
    /// server errors.
    pub fn is_retryable(status_code: i64) -> bool {
        status_code == 408 || status_code == 429 || (500..=599).contains(&status_code)
    }

    /// Backoff delay before the retry following zero-based `attempt`. An
    /// explicit `retry_after` (from a `Retry-After` header) wins, capped at
    /// `max_delay`. Uses the Swift default of 0.5 for the jitter unit.
    pub fn delay(&self, attempt: i64, retry_after: Option<f64>) -> f64 {
        self.delay_with_random_unit(attempt, retry_after, 0.5)
    }

    /// `random_unit` (0…1) injects jitter deterministically so tests can pin
    /// the result.
    pub fn delay_with_random_unit(
        &self,
        attempt: i64,
        retry_after: Option<f64>,
        random_unit: f64,
    ) -> f64 {
        if let Some(retry_after) = retry_after
            && retry_after > 0.0
        {
            return retry_after.min(self.max_delay);
        }
        let exponential = self.base_delay * 2f64.powf(attempt.max(0) as f64);
        let capped = exponential.min(self.max_delay);
        // Map random_unit 0…1 to a ±jitter multiplier around the capped delay.
        let spread = capped * self.jitter * (random_unit * 2.0 - 1.0);
        (capped + spread).max(0.0)
    }
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self::with_defaults()
    }
}
