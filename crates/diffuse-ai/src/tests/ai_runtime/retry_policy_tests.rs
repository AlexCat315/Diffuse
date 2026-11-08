//! Ported from `Engine/Tests/AIRuntimeTests/RetryPolicyTests.swift`.
//!
//! Rust's `max_retries` is a `usize`, so a negative retry count cannot be
//! expressed at all; the clamping case pins `0` and checks only the floating
//! inputs that Rust does clamp.

use crate::session::retry_policy::RetryPolicy;

#[test]
fn retryable_status_codes() {
    assert!(RetryPolicy::is_retryable(408));
    assert!(RetryPolicy::is_retryable(429));
    assert!(RetryPolicy::is_retryable(500));
    assert!(RetryPolicy::is_retryable(503));
    assert!(RetryPolicy::is_retryable(599));

    assert!(!RetryPolicy::is_retryable(200));
    assert!(!RetryPolicy::is_retryable(400));
    assert!(!RetryPolicy::is_retryable(401));
    assert!(!RetryPolicy::is_retryable(404));
}

#[test]
fn exponential_backoff_doubles_per_attempt() {
    let policy = RetryPolicy::new(5, 1.0, 100.0, 0.0);
    assert!((policy.delay(0, None) - 1.0).abs() < 1e-9);
    assert!((policy.delay(1, None) - 2.0).abs() < 1e-9);
    assert!((policy.delay(2, None) - 4.0).abs() < 1e-9);
    assert!((policy.delay(3, None) - 8.0).abs() < 1e-9);
}

#[test]
fn backoff_is_capped_at_max_delay() {
    let policy = RetryPolicy::new(10, 1.0, 5.0, 0.0);
    assert!((policy.delay(10, None) - 5.0).abs() < 1e-9);
}

#[test]
fn retry_after_overrides_and_is_capped() {
    let policy = RetryPolicy::new(3, 1.0, 20.0, 0.0);
    assert!((policy.delay(0, Some(7.0)) - 7.0).abs() < 1e-9);
    // Retry-After above maxDelay is capped.
    assert!((policy.delay(0, Some(100.0)) - 20.0).abs() < 1e-9);
}

#[test]
fn jitter_stays_within_bounds() {
    let policy = RetryPolicy::new(3, 10.0, 100.0, 0.2);
    let low = policy.delay_with_random_unit(0, None, 0.0); // -20%
    let mid = policy.delay_with_random_unit(0, None, 0.5); // center
    let high = policy.delay_with_random_unit(0, None, 1.0); // +20%
    assert!((low - 8.0).abs() < 1e-6);
    assert!((mid - 10.0).abs() < 1e-6);
    assert!((high - 12.0).abs() < 1e-6);
}

#[test]
fn clamps_negative_inputs() {
    let policy = RetryPolicy::new(0, -1.0, -1.0, 5.0);
    assert_eq!(policy.max_retries, 0);
    assert_eq!(policy.base_delay, 0.0);
    assert_eq!(policy.jitter, 1.0);
}

#[test]
fn none_policy_disables_retries() {
    assert_eq!(RetryPolicy::none().max_retries, 0);
}
