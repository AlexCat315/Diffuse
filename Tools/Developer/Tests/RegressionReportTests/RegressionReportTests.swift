import Foundation
import XCTest

@testable import RegressionReport

/// Port of `scripts/test-gpu-regression-verifier.py`, guarding CI against
/// unrun, skipped, failed, or partially reported GPU tests.
final class RegressionReportTests: XCTestCase {
  func testStartedTestsAndSuiteSummariesCannotSatisfyInventory() throws {
    let cases = try Verification.xctestCases(
      from:
        "Test Case '-[Module.SceneTests draw]' started.\n"
        + "Test Suite 'SceneTests' passed at 2026-10-11.\n")
    XCTAssertEqual(cases.count, 0)
    try expectFailure("incomplete", from: cases, suites: ["SceneTests"], methods: ["draw"])
  }

  func testCompletedAppleAndPortableXCTestRecordsSatisfyInventory() throws {
    let cases = try Verification.xctestCases(
      from:
        "Test Case '-[Module.SceneTests draw]' passed (0.012 seconds).\n"
        + "Test Case 'SurfaceTests.resize' passed (0.023 seconds).\n")
    try Verification.verifyCases(
      cases, suites: ["SceneTests", "SurfaceTests"], methods: ["draw", "resize"])
  }

  func testSkippedOrFailedTestFailsEvenWhenRequiredTestsPass() throws {
    for status in ["skipped", "failed"] {
      let cases = try Verification.xctestCases(
        from:
          "Test Case 'SceneTests.draw' passed (0.012 seconds).\n"
          + "Test Case 'SceneTests.resize' \(status) (0.023 seconds).\n")
      try expectFailure("skipped or failed", from: cases, suites: ["SceneTests"], methods: ["draw"])
    }
  }

  func testMissingSuiteOrMethodFails() throws {
    let cases = try Verification.xctestCases(
      from:
        "Test Case 'SceneTests.draw' passed (0.012 seconds).\n")
    for (suites, methods) in [
      (Set(["SurfaceTests"]), Set(["draw"])),
      (Set(["SceneTests"]), Set(["resize"])),
    ] {
      try expectFailure("incomplete", from: cases, suites: suites, methods: methods)
    }
  }

  func testSwiftTestingXMLAndXCTestLogAreBothRequiredAndMerged() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(
      "<testsuite><testcase classname=\"Module.SmokeTests\" name=\"render()\"/></testsuite>",
      to: directory.appendingPathComponent("gpu-results-swift-testing.xml"))
    try write(
      "Test Case '-[Module.SurfaceTests resize]' passed (0.023 seconds).\n",
      to: directory.appendingPathComponent("gpu.log"))
    let cases = try Verification.loadCases(reportDirectory: directory, prefix: "gpu")
    try Verification.verifyCases(
      cases, suites: ["SmokeTests", "SurfaceTests"], methods: ["render", "resize"])
    let written = try XUnit.testCases(at: directory.appendingPathComponent("gpu-xctest.xml"))
    XCTAssertEqual(written.count, 1)
  }

  func testNativeXMLIsNotCountedTwiceAndCannotHideALoggedFailure() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(
      "<testsuite><testcase classname=\"Module.SurfaceTests\" name=\"resize\"/></testsuite>",
      to: directory.appendingPathComponent("ui-results.xml"))
    let log = directory.appendingPathComponent("ui.log")
    try write("Test Case '-[Module.SurfaceTests resize]' passed (0.023 seconds).\n", to: log)
    let cases = try Verification.loadCases(reportDirectory: directory, prefix: "ui")
    XCTAssertEqual(cases.count, 1)
    try write("Test Case '-[Module.SurfaceTests resize]' failed (0.023 seconds).\n", to: log)
    let failed = try Verification.loadCases(reportDirectory: directory, prefix: "ui")
    try expectFailure(
      "skipped or failed", from: failed, suites: ["SurfaceTests"], methods: ["resize"])
  }

  func testMissingXMLIsRejected() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertThrowsError(try Verification.loadCases(reportDirectory: directory, prefix: "gpu")) {
      error in
      XCTAssertTrue(String(describing: error).contains("did not produce"))
    }
  }

  // MARK: - Helpers

  private func expectFailure(
    _ fragment: String, from cases: [TestCase],
    suites: Set<String>, methods: Set<String>
  ) throws {
    XCTAssertThrowsError(try Verification.verifyCases(cases, suites: suites, methods: methods)) {
      error in
      XCTAssertTrue(
        String(describing: error).contains(fragment),
        "expected '\(fragment)' in '\(String(describing: error))'")
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("guava-regression-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
  }
}
