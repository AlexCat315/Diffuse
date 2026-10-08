// NativeRHITests — shared test bundle for the NativeRHI module.
//
// Core, platform-independent tests (submission planner, caches, state/upload/
// frame rings) live at the top level of this target. Backend-specific tests
// live in subdirectories: Metal/ (GPU integration, guarded by Metal availability)
// and Vulkan/ (guarded by canImport(CVulkanHeaders) and runtime availability).

import XCTest
@testable import NativeRHI

final class NativeRHISmokeTests: XCTestCase {
    func testModuleVersionIsPresent() {
        XCTAssertFalse(NativeRHI.version.isEmpty)
    }

    func testDefaultBackendsNonEmpty() {
        XCTAssertFalse(NativeRHI.platformDefaultBackends.isEmpty)
    }
}
