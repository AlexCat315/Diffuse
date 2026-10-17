internal import Foundation
internal import ToolSupport

/// Runs an async body to completion for the synchronous `Validation.run`
/// entry point. The calling thread blocks; the body runs on the concurrency
/// pool, which is where the `URLSessionWebSocketTask` awaits live.
enum AsyncBridge {
  static func wait<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let result = Box<Result<T, any Error>>()
    let work = Box(body)
    Task {
      defer { semaphore.signal() }
      guard let body = work.get() else { return }
      do { result.set(.success(try await body())) } catch { result.set(.failure(error)) }
    }
    semaphore.wait()
    guard let outcome = result.get() else {
      throw ToolError.message("Async validation did not complete")
    }
    return try outcome.get()
  }
}
