#if os(macOS)
import Foundation

/// GPU errors are recorded on completion threads and surfaced on the API
/// thread at waitUntilIdle. Registry mutation stays on the API thread.
final class MetalSubmissionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: RHIError?

    func record(_ description: String) {
        lock.withLock { failure = failure ?? .submitFailed(description) }
    }

    func check() throws {
        try lock.withLock {
            if let failure { throw failure }
        }
    }
}
#endif
