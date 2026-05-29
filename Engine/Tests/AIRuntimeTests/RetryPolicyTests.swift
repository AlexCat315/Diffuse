import XCTest
@testable import AIRuntime

final class RetryPolicyTests: XCTestCase {

    func testRetryableStatusCodes() {
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 408))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 429))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 500))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 503))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 599))

        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 200))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 400))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 401))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 404))
    }

    func testExponentialBackoffDoublesPerAttempt() {
        let policy = RetryPolicy(maxRetries: 5, baseDelay: 1, maxDelay: 100, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 1), 2, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 2), 4, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 3), 8, accuracy: 1e-9)
    }

    func testBackoffIsCappedAtMaxDelay() {
        let policy = RetryPolicy(maxRetries: 10, baseDelay: 1, maxDelay: 5, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 10), 5, accuracy: 1e-9)
    }

    func testRetryAfterOverridesAndIsCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 20, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 0, retryAfter: 7), 7, accuracy: 1e-9)
        // Retry-After above maxDelay is capped.
        XCTAssertEqual(policy.delay(forAttempt: 0, retryAfter: 100), 20, accuracy: 1e-9)
    }

    func testJitterStaysWithinBounds() {
        let policy = RetryPolicy(baseDelay: 10, maxDelay: 100, jitter: 0.2)
        let low = policy.delay(forAttempt: 0, randomUnit: 0)   // -20%
        let mid = policy.delay(forAttempt: 0, randomUnit: 0.5) // center
        let high = policy.delay(forAttempt: 0, randomUnit: 1)  // +20%
        XCTAssertEqual(low, 8, accuracy: 1e-6)
        XCTAssertEqual(mid, 10, accuracy: 1e-6)
        XCTAssertEqual(high, 12, accuracy: 1e-6)
    }

    func testClampsNegativeInputs() {
        let policy = RetryPolicy(maxRetries: -3, baseDelay: -1, maxDelay: -1, jitter: 5)
        XCTAssertEqual(policy.maxRetries, 0)
        XCTAssertEqual(policy.baseDelay, 0)
        XCTAssertEqual(policy.jitter, 1)
    }

    func testNonePolicyDisablesRetries() {
        XCTAssertEqual(RetryPolicy.none.maxRetries, 0)
    }
}
