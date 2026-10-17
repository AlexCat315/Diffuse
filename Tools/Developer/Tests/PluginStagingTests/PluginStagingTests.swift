import Foundation
import XCTest

@testable import PluginStaging

/// Port of `Engine/third-party/wasmtime/tests/test_staging.py`.
final class PluginStagingTests: XCTestCase {
  func testVariantsAndIntegrity() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("guava-staging-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installed = root.appendingPathComponent("installed")
    try FileManager.default.createDirectory(
      at: installed.appendingPathComponent("include"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: installed.appendingPathComponent("lib"), withIntermediateDirectories: true)
    try Data("header".utf8).write(to: installed.appendingPathComponent("include/wasmtime.h"))
    try Data("static".utf8).write(to: installed.appendingPathComponent("lib/libwasmtime.a"))
    try Data("license".utf8).write(to: installed.appendingPathComponent("LICENSE"))

    let vendor = root.appendingPathComponent("vendor")
    let ios = Catalog.Platform(triple: "arm64-apple-ios-simulator")
    let mac = Catalog.Platform(triple: "arm64-apple-macosx")
    let source = Provenance.Source(url: "https://example.com/source", sha256: "source")

    try PluginStaging.stage(installed, vendor, "macos-arm64", mac, "49.0.2", source)
    try PluginStaging.stage(installed, vendor, "ios-arm64-simulator", ios, "49.0.2", source)
    XCTAssertTrue(PluginStaging.ready(vendor, "macos-arm64", mac, "49.0.2", "source"))
    XCTAssertTrue(PluginStaging.ready(vendor, "ios-arm64-simulator", ios, "49.0.2", "source"))
    XCTAssertFalse(
      PluginStaging.ready(vendor, "ios-arm64-simulator", ios, "49.0.2", "changed-source"))

    let bundle = vendor.appendingPathComponent("Wasmtime.artifactbundle")
    try Data("broken".utf8).write(
      to: bundle.appendingPathComponent("ios-arm64-simulator/include/wasmtime.h"))
    XCTAssertFalse(PluginStaging.ready(vendor, "ios-arm64-simulator", ios, "49.0.2", "source"))

    XCTAssertThrowsError(
      try PluginStaging.stage(installed, vendor, "macos-arm64", mac, "50.0.0", source))
    XCTAssertTrue(PluginStaging.ready(vendor, "macos-arm64", mac, "49.0.2", "source"))

    try FileManager.default.removeItem(at: installed.appendingPathComponent("lib/libwasmtime.a"))
    XCTAssertThrowsError(
      try PluginStaging.stage(installed, vendor, "macos-arm64", mac, "49.0.2", source))
    XCTAssertTrue(PluginStaging.ready(vendor, "macos-arm64", mac, "49.0.2", "source"))
  }
}
