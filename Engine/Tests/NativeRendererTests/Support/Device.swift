import Foundation
import XCTest
@testable import NativeRHI

/// Ordinary CI can lack a Vulkan ICD. Explicit GPU regression must fail there.
enum RendererTestDevice {
    static func make(_ config: DeviceConfig = DeviceConfig()) throws -> Device {
        #if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
        if config.preferredBackends.first == .vulkan,
           !VulkanBackend.isAvailable,
           ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] != "1" {
            throw XCTSkip("No native Vulkan driver; GPU regression requires a hardware runner")
        }
        #endif
        return try Device.make(config)
    }
}
