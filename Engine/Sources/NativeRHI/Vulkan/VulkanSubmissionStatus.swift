#if canImport(CVulkanHeaders)
import Foundation

final class VulkanSubmissionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: RHIError?
    func record(_ description: String) { lock.withLock { failure = failure ?? .submitFailed(description) } }
    func check() throws { try lock.withLock { if let failure { throw failure } } }
}
#endif
