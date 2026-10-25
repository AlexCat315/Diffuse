internal import XCTest
@testable private import RuntimeValidation

final class AsyncBridgeTests: XCTestCase {
  /// CLI @main entry points must not enqueue the work onto the actor whose
  /// thread is synchronously waiting for that work to finish.
  /// Linux test discovery cannot cast actor-isolated test methods; XCTest
  /// already runs them on the main thread.
  func testSynchronousMainActorEntryCanAwaitAsynchronousWork() throws {
    let result = try MainActor.assumeIsolated {
      try AsyncBridge.wait { await Self.valueAfterSuspension() }
    }
    XCTAssertEqual(result, 42)
  }

  private static func valueAfterSuspension() async -> Int {
    await Task.yield()
    return 42
  }
}
