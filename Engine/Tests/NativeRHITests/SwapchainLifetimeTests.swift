import Foundation
import XCTest
@testable import NativeRHI

private final class PresentationUploader: FrameUploader {
    func reset() {}
    func write(_ data: Data, alignment: Int) throws -> UploadLocation { throw RHIError.outOfMemory }
}

/// Holds presentation completion independently from rendering, so these tests
/// can prove frame-slot and window retirement without relying on GPU timing.
private final class PresentationBackend: RHIBackend, @unchecked Sendable {
    let api: GraphicsAPI = .metal
    let deviceName = "controlled presentation"
    private let lock = NSLock()
    private var windows: [UInt32: SurfaceDescriptor] = [:]
    private var completions: [() -> Void] = []
    private var failNextIdle = false
    func rejectNextIdle() { lock.withLock { failNextIdle = true } }
    private var failNextPresent = false
    func rejectNextPresent() { lock.withLock { failNextPresent = true } }

    var pendingCount: Int { lock.withLock { completions.count } }
    var windowCount: Int { lock.withLock { windows.count } }
    func complete() { let bodies = lock.withLock { let result = completions; completions.removeAll(); return result }; bodies.forEach { $0() } }
    func queryCapabilities() -> Capabilities { Capabilities() }
    func queryAdapterCapabilities() -> AdapterCapabilities { AdapterCapabilities() }
    func configureSwapchain(_ handle: Swapchain, descriptor: SurfaceDescriptor) throws { lock.withLock { windows[handle.id] = descriptor } }
    func destroySwapchain(_ handle: Swapchain) { _ = lock.withLock { windows.removeValue(forKey: handle.id) } }
    func acquireSwapchainImage(_ handle: Swapchain) throws -> SwapchainImage {
        let descriptor = try lock.withLock { try XCTUnwrap(windows[handle.id]) }
        return SwapchainImage(swapchain: handle, generation: 1, texture: Texture(id: 0x8000_0000 + handle.id),
            width: descriptor.width, height: descriptor.height)
    }
    func present(_ image: SwapchainImage, completion: @escaping () -> Void) throws {
        try lock.withLock {
            if failNextPresent { failNextPresent = false; throw RHIError.presentFailed("before queueing") }
            completions.append(completion)
        }
    }
    func makeFrameUploader(slot: Int) -> FrameUploader { PresentationUploader() }
    func submit(_ submit: PlannedSubmit, cpuProfile: SubmissionCPUProfile?, completion: @escaping () -> Void) throws { completion() }
    func waitUntilIdle() throws {
        try lock.withLock {
            if failNextIdle { failNextIdle = false; throw RHIError.submitFailed("completed GPU work reported an error") }
        }
    }
    func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws { throw RHIError.outOfMemory }
    func createTexture(_ handle: Texture, descriptor: TextureDescriptor) throws { throw RHIError.outOfMemory }
    func createSampler(_ handle: Sampler, descriptor: SamplerDescriptor) throws { throw RHIError.outOfMemory }
    func createShaderModule(_ handle: ShaderModule, descriptor: ShaderModuleDescriptor) throws { throw RHIError.outOfMemory }
    func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws { throw RHIError.outOfMemory }
    func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws { throw RHIError.outOfMemory }
    func registerBindingSet(_ handle: BindingSet, layout: BindingLayout, layoutEntries: [BindingLayoutEntry], setEntries: [BindingSetEntry]) throws { throw RHIError.outOfMemory }
    func unregisterBindingSet(_ handle: BindingSet) {}
    func uploadBufferData(_ buffer: Buffer, offset: Int, data: Data) throws { throw RHIError.outOfMemory }
    func uploadTextureData(_ texture: Texture, data: Data, region: TextureUploadRegion, bytesPerRow: Int, subresource: TextureSubresource) throws { throw RHIError.outOfMemory }
    func readTextureData(_ texture: Texture, width: Int, height: Int, bytesPerRow: Int, subresource: TextureSubresource, into destination: UnsafeMutableRawBufferPointer) throws { throw RHIError.outOfMemory }
    func destroyBuffer(_ handle: Buffer) {}
    func destroyTexture(_ handle: Texture) {}
    func destroySampler(_ handle: Sampler) {}
    func destroyShaderModule(_ handle: ShaderModule) {}
    func destroyGraphicsPipeline(_ handle: GraphicsPipeline) {}
    func destroyComputePipeline(_ handle: ComputePipeline) {}
}

private final class FrameSessionWorker: @unchecked Sendable {
    let device: Device
    let started = DispatchSemaphore(value: 0)
    let entering = DispatchSemaphore(value: 0)
    let began = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    var error: Error?
    init(device: Device) { self.device = device }
    func run() {
        started.signal()
        do {
            try device.withFrameSession {
                entering.signal()
                try device.beginFrame()
                began.signal()
                device.endFrame()
            }
        } catch { self.error = error }
        finished.signal()
    }
}

final class SwapchainLifetimeTests: XCTestCase {
    private func context() throws -> (Device, PresentationBackend) {
        let backend = PresentationBackend()
        return (try Device(backend: backend, config: DeviceConfig(preferredBackends: [.metal], framesInFlight: 1)), backend)
    }
    private func descriptor(_ id: Int = 1) -> SurfaceDescriptor {
        SurfaceDescriptor(nativeHandle: UnsafeMutableRawPointer(bitPattern: id), width: 16, height: 16)
    }

    func testFrameSessionsSerializePreparationAndReleaseAfterErrors() throws {
        let (device, _) = try context()
        let worker = FrameSessionWorker(device: device)
        XCTAssertThrowsError(try device.withFrameSession {
            DispatchQueue.global().async { worker.run() }
            XCTAssertEqual(worker.started.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(worker.entering.wait(timeout: .now() + 0.05), .timedOut)
            throw RHIError.invalidArgument("failed preparation")
        })
        XCTAssertEqual(worker.finished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(worker.error)
        try device.withFrameSession {
            try device.beginFrame()
            XCTAssertThrowsError(try device.withFrameSession { try device.beginFrame() })
            device.endFrame()
        }
    }

    func testPresentationCompletionProtectsSlotReuseAndOwnedWindowRetirement() throws {
        let (device, backend) = try context()
        var resource: SwapchainResource? = try SwapchainResource(device: device, descriptor: descriptor())
        let handle = try XCTUnwrap(resource?.swapchain)
        try device.beginFrame()
        let image = try device.acquireSwapchainImage(handle)
        try device.present(image)
        resource = nil
        device.endFrame()
        XCTAssertEqual(backend.windowCount, 1)
        let worker = FrameSessionWorker(device: device)
        DispatchQueue.global().async { worker.run() }
        XCTAssertEqual(worker.entering.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(worker.began.wait(timeout: .now() + 0.05), .timedOut)
        backend.complete()
        XCTAssertEqual(worker.finished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(worker.error)
        XCTAssertEqual(backend.windowCount, 0)
        try device.waitUntilIdle()
    }

    func testAbandonedAcquisitionIsReturnedAndTracked() throws {
        let (device, backend) = try context()
        let handle = try device.makeSwapchain(descriptor())
        try device.beginFrame()
        _ = try device.acquireSwapchainImage(handle)
        device.endFrame()
        XCTAssertEqual(backend.pendingCount, 1)
        backend.complete()
        try device.beginFrame()
        let next = try device.acquireSwapchainImage(handle)
        try device.present(next)
        device.endFrame()
        backend.complete()
        try device.waitUntilIdle()
        device.destroy(handle)
        XCTAssertEqual(backend.windowCount, 0)
    }

    func testOwnedCloseIsIdempotentAndCleansUpAfterCompletedWorkErrors() throws {
        let (device, backend) = try context()
        let resource = try SwapchainResource(device: device, descriptor: descriptor())
        try device.beginFrame()
        XCTAssertThrowsError(try resource.close())
        XCTAssertEqual(backend.windowCount, 1)
        device.endFrame()
        backend.rejectNextIdle()
        XCTAssertThrowsError(try resource.close())
        XCTAssertEqual(backend.windowCount, 0)
        try resource.close()
        try device.beginFrame()
        XCTAssertThrowsError(try device.acquireSwapchainImage(resource.swapchain))
        device.endFrame()
    }

    func testOldTicketIsRejectedWhenTheSamePoolTextureIsAcquiredAgain() throws {
        let (device, backend) = try context()
        let handle = try device.makeSwapchain(descriptor())
        try device.beginFrame()
        let old = try device.acquireSwapchainImage(handle)
        try device.present(old); device.endFrame(); backend.complete()
        try device.beginFrame()
        let current = try device.acquireSwapchainImage(handle)
        XCTAssertEqual(old.texture, current.texture)
        XCTAssertEqual(old.generation, current.generation)
        XCTAssertNotEqual(old, current)
        XCTAssertThrowsError(try device.present(old))
        try device.present(current); device.endFrame(); backend.complete()
        try device.waitUntilIdle()
        device.destroy(handle)
    }

    func testRejectedPresentCanRetryWithoutDuplicatingCompletion() throws {
        let (device, backend) = try context()
        let handle = try device.makeSwapchain(descriptor())
        try device.beginFrame()
        let image = try device.acquireSwapchainImage(handle)
        backend.rejectNextPresent()
        XCTAssertThrowsError(try device.present(image))
        XCTAssertEqual(backend.pendingCount, 0)
        try device.present(image)
        XCTAssertThrowsError(try device.present(image))
        XCTAssertThrowsError(try device.acquireSwapchainImage(handle))
        device.endFrame()
        XCTAssertEqual(backend.pendingCount, 1)
        backend.complete()
        try device.waitUntilIdle()
        device.destroy(handle)
    }
}
