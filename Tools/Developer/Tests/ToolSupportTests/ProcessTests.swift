import Foundation
import ToolSupport
import XCTest

final class ProcessTests: XCTestCase {
  func testNonzeroExitRemainsAvailableToCaller() throws {
    #if os(Windows)
      let command = ["cmd.exe", "/c", "exit 7"]
    #else
      let command = ["sh", "-c", "exit 7"]
    #endif
    XCTAssertEqual(try ProcessRunner.run(command, timeout: 5).status, 7)
  }

  #if !os(Windows)
    func testLargeInputAndBothOutputStreamsCannotBlockEachOther() throws {
      let payload = Data(repeating: 65, count: 512 * 1024)
      let result = try ProcessRunner.run(
        ["sh", "-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2; cat"],
        input: payload, timeout: 10)
      XCTAssertEqual(result.status, 0)
      XCTAssertEqual(result.stdout, Data(repeating: 0, count: 262144) + payload)
      XCTAssertEqual(result.stderr, Data(repeating: 0, count: 262144))
    }

    func testDeadlineStillAppliesAfterChildClosesOutput() {
      let start = Date()
      XCTAssertThrowsError(
        try ProcessRunner.run(["sh", "-c", "exec 1>&- 2>&-; exec sleep 10"], timeout: 0.15))
      XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testShellCanFeedInputLargerThanAPipeBuffer() throws {
      let payload = String(repeating: "abcdef", count: 100_000)
      XCTAssertEqual(try Shell.run(["cat"], capture: true, echo: false, input: payload), payload)
    }
  #endif
}
