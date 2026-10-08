import Foundation
import XCTest
@testable import NativeRHI

final class ShaderArtifactTests: XCTestCase {
    func testArtifactRoundTripKeepsWorkgroupSizeAndCode() throws {
        var artifact = ShaderArtifact(stage: .compute, format: .mslSource,
            entryPoint: "main", code: Data("shader".utf8), compiler: "test")
        artifact.interface.threadgroupSize = ThreadgroupSize(x: 8, y: 2)
        let decoded = try JSONDecoder().decode(ShaderArtifact.self, from: JSONEncoder().encode(artifact))
        let module = try decoded.moduleDescriptor()
        XCTAssertEqual(module.threadgroupSize, ThreadgroupSize(x: 8, y: 2))
        XCTAssertEqual(module.code, artifact.code)
    }

    func testInvalidAndOverflowingWorkgroupSizesAreRejected() {
        XCTAssertThrowsError(try ThreadgroupSize(x: 0).validate())
        XCTAssertThrowsError(try ThreadgroupSize(x: -1).validate())
        XCTAssertThrowsError(try ThreadgroupSize(x: Int.max, y: 2).validate())
    }

    func testUnimplementedCapabilitiesDefaultToFalse() {
        let caps = Capabilities()
        XCTAssertFalse(caps.rayTracing.pipelines)
        XCTAssertFalse(caps.rayTracing.update)
        XCTAssertFalse(caps.meshShading.indirect)
        XCTAssertEqual(caps.maxQueues.graphics, 0)
    }
}
