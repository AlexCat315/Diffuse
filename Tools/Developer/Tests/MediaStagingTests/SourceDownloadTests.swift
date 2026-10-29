import Foundation
import XCTest
import ToolSupport
@testable import MediaStaging

final class SourceDownloadTests: XCTestCase {
  private let remote = URL(string: "https://ffmpeg.org/releases/fixture.tar.xz")!

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testVerifiedCacheNeedsNoDownloaderOrNetwork() throws {
    let destination = try temporaryDirectory().appendingPathComponent("source.tar.xz")
    try Data("verified source".utf8).write(to: destination)
    try SourceDownload.fetch(from: remote, to: destination, sha256: SHA256.hex(file: destination),
                             environment: ["PATH": ""]) { _, _ in
      XCTFail("A verified cache must not perform a transfer")
    }
  }

  func testSuccessfulTransferIsVerifiedAndPublishedAtomically() throws {
    let root = try temporaryDirectory(), destination = root.appendingPathComponent("source.tar.xz")
    let expected = root.appendingPathComponent("expected")
    try Data("pinned source".utf8).write(to: expected)
    try SourceDownload.fetch(from: remote, to: destination, sha256: SHA256.hex(file: expected),
                             environment: ProcessInfo.processInfo.environment) { command, _ in
      XCTAssertTrue(command.contains("--retry-all-errors"))
      let timeout = try XCTUnwrap(command.firstIndex(of: "--max-time"))
      XCTAssertGreaterThan(try XCTUnwrap(Int(command[timeout + 1])), 60)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      let output = try XCTUnwrap(command.firstIndex(of: "--output"))
      try FileManager.default.copyItem(at: expected, to: URL(fileURLWithPath: command[output + 1]))
    }
    XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: expected))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".ffmpeg-download-") })
  }

  func testInterruptedAndCorruptTransfersPreserveExistingArchiveAndRemoveStagingFiles() throws {
    for interrupted in [false, true] {
      let root = try temporaryDirectory(), destination = root.appendingPathComponent("source.tar.xz")
      let original = Data("previous archive".utf8)
      try original.write(to: destination)
      XCTAssertThrowsError(try SourceDownload.fetch(from: remote, to: destination, sha256: String(repeating: "0", count: 64),
                                                    environment: ProcessInfo.processInfo.environment) { command, _ in
        let output = try XCTUnwrap(command.firstIndex(of: "--output"))
        try Data("partial or corrupt data".utf8).write(to: URL(fileURLWithPath: command[output + 1]))
        if interrupted { throw URLError(.timedOut) }
      })
      XCTAssertEqual(try Data(contentsOf: destination), original)
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".ffmpeg-download-") })
    }
  }

  func testNonHTTPSURLIsRejectedBeforeTransfer() throws {
    let destination = try temporaryDirectory().appendingPathComponent("source.tar.xz")
    XCTAssertThrowsError(try SourceDownload.fetch(from: URL(string: "http://ffmpeg.org/source")!, to: destination,
                                                  sha256: "", environment: [:]) { _, _ in
      XCTFail("An insecure URL must not reach the downloader")
    })
  }
  func testUnavailableOrCorruptMirrorFallsBackWithoutPublishingItsData() throws {
    for corrupt in [false, true] {
      let root = try temporaryDirectory(), destination = root.appendingPathComponent("source.tar.xz")
      let expected = root.appendingPathComponent("expected")
      let previous = Data("previous archive".utf8)
      try previous.write(to: destination)
      try Data("pinned source".utf8).write(to: expected)
      let mirrors = [URL(string: "https://unreachable.invalid/fixture")!, remote]
      var attempted: [String] = []
      var stagingPaths: [String] = []
      try SourceDownload.fetch(from: mirrors, to: destination, sha256: SHA256.hex(file: expected),
                               environment: ProcessInfo.processInfo.environment) { command, _ in
        attempted.append(try XCTUnwrap(command.last))
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        let output = try XCTUnwrap(command.firstIndex(of: "--output"))
        let staging = URL(fileURLWithPath: command[output + 1])
        stagingPaths.append(staging.path)
        if attempted.count == 1 {
          try Data("corrupt or interrupted source".utf8).write(to: staging)
          if !corrupt { throw URLError(.timedOut) }
        } else {
          XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPaths[0]))
          try FileManager.default.copyItem(at: expected, to: staging)
        }
      }
      XCTAssertEqual(attempted, mirrors.map(\.absoluteString))
      XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: expected))
      XCTAssertTrue(stagingPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }
  }

  func testInsecureFallbackIsRejectedBeforeAnyTransfer() throws {
    let destination = try temporaryDirectory().appendingPathComponent("source.tar.xz")
    XCTAssertThrowsError(try SourceDownload.fetch(from: [remote, URL(string: "http://invalid/source")!],
      to: destination, sha256: "", environment: [:]) { _, _ in
      XCTFail("Every mirror must be validated before downloading")
    })
  }

  func testRealPinnedSourceDownload() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["COVE_TEST_FFMPEG_SOURCE"] == "1")
    let destination = try temporaryDirectory().appendingPathComponent("ffmpeg.tar.xz")
    try SourceDownload.fetch(from: MediaStaging.sourceURLs, to: destination,
                             sha256: MediaStaging.sourceSHA256, environment: ProcessInfo.processInfo.environment)
    try Download.verify(file: destination, sha256: MediaStaging.sourceSHA256)
  }

}
