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
}
