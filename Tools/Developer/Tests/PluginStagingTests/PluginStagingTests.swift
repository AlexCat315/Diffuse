private import Foundation
internal import XCTest
@testable internal import PluginStaging

final class PluginStagingTests: XCTestCase {
    func testCatalogIsDesktopOnlyAndIntegrityIsRequired() throws {
        let catalog = try BunCatalog.read()
        XCTAssertEqual(catalog.version, "1.4.4")
        XCTAssertEqual(Set(catalog.platforms.keys), ["macos-arm64", "macos-x86_64", "linux-aarch64", "linux-x86_64", "windows-arm64", "windows-x86_64"])
        for variant in catalog.platforms.values {
            XCTAssertEqual(variant.sha256.count, 64)
            XCTAssertTrue(variant.archive.hasPrefix("bun-"))
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(PluginStaging.ready(missing, version: catalog.version, platform: PluginStaging.host(), archive: "wrong"))
    }
}
