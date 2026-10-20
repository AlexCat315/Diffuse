import Foundation
import Testing
@testable import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Image cache, sharing, orientation and animation")
struct ImagePipelineTests {
    private func image(_ value: UInt8, width: Int = 4, height: Int = 4) -> DecodedImage {
        DecodedImage(pixels: [UInt8](repeating: value, count: width * height * 4), width: width, height: height)
    }

    @Test("The registry evicts least recently used assets past its byte and count budgets")
    func eviction() throws {
        let registry = ImageAssetRegistry(limits: .init(maximumBytes: 64 * 3, maximumCount: 10))
        try registry.register(key: "a", decoded: image(1))
        try registry.register(key: "b", decoded: image(2))
        try registry.register(key: "c", decoded: image(3))
        #expect(registry.cachedBytes == 192)
        _ = registry.cached("a") // a becomes most recent
        try registry.register(key: "d", decoded: image(4))
        #expect(registry.cached("b") == nil)
        #expect(registry.cached("a") != nil && registry.cached("c") != nil && registry.cached("d") != nil)
        registry.limits = .init(maximumBytes: .max, maximumCount: 1)
        #expect(registry.cachedCount == 1)
        // An entry larger than the whole budget is still returned and kept.
        let tiny = ImageAssetRegistry(limits: .init(maximumBytes: 8, maximumCount: 4))
        let big = try tiny.register(key: "big", decoded: image(9))
        #expect(tiny.cached("big") === big)
        registry.clear()
        #expect(registry.cachedBytes == 0)
    }

    @Test("Concurrent requests for one key share a single decode")
    func inflightSharing() async throws {
        let loads = ImageInflightLoads()
        let counter = Counter()
        let gate = Gate()
        async let first = loads.load(key: "k", progress: { _ in }) { _ in
            await counter.increment(); await gate.wait(); return .still(DecodedImage(pixels: [0, 0, 0, 255], width: 1, height: 1))
        }
        async let second = loads.load(key: "k", progress: { _ in }) { _ in
            await counter.increment(); await gate.wait(); return .still(DecodedImage(pixels: [0, 0, 0, 255], width: 1, height: 1))
        }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        _ = try await (first, second)
        #expect(await counter.value == 1)
        #expect(loads.activeCount == 0)
    }

    @Test("Cancelling the last waiter cancels the shared work")
    func inflightCancellation() async throws {
        let loads = ImageInflightLoads()
        let started = Gate()
        let task = Task {
            try await loads.load(key: "slow", progress: { _ in }) { _ in
                await started.open()
                try await Task.sleep(for: .seconds(30))
                return .still(DecodedImage(pixels: [0, 0, 0, 255], width: 1, height: 1))
            }
        }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(loads.activeCount == 0)
    }

    @Test("EXIF orientation is read from APP1 and applied to pixels")
    func orientation() {
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x22]
        jpeg += Array("Exif".utf8) + [0, 0]
        jpeg += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        jpeg += [0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00]
        jpeg += [0x00, 0x00, 0x00, 0x00, 0xFF, 0xD9]
        #expect(ImageOrientation.read(Data(jpeg)) == 6)
        #expect(ImageOrientation.read(Data([0x89, 0x50, 0x4E, 0x47])) == 1)
        // 2×1: red, green → rotated 90° clockwise becomes 1×2: red on top.
        let source = DecodedImage(pixels: [255, 0, 0, 255, 0, 255, 0, 255], width: 2, height: 1)
        let rotated = ImageOrientation.apply(6, to: source)
        #expect(rotated.width == 1 && rotated.height == 2)
        #expect(Array(rotated.pixels[0..<4]) == [255, 0, 0, 255])
        let ccw = ImageOrientation.apply(8, to: source)
        #expect(Array(ccw.pixels[0..<4]) == [0, 255, 0, 255])
        let mirrored = ImageOrientation.apply(2, to: source)
        #expect(Array(mirrored.pixels[0..<4]) == [0, 255, 0, 255])
        #expect(ImageOrientation.swapsAxes(5) && !ImageOrientation.swapsAxes(3))
    }

    @Test("A two-frame GIF decodes as an animation with browser-style durations")
    func gifAnimation() throws {
        var gif: [UInt8] = Array("GIF89a".utf8) + [0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00]
        gif += [0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00]
        func frame(_ data: UInt8, delay: UInt8) -> [UInt8] {
            [0x21, 0xF9, 0x04, 0x00, delay, 0x00, 0x00, 0x00,
             0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
             0x02, 0x02, data, 0x01, 0x00]
        }
        gif += frame(0x44, delay: 10) + frame(0x4C, delay: 1) + [0x3B]
        let data = Data(gif)
        #expect(ImageDecoder.isAnimatable(data: data, formatHint: "gif"))
        let animation = try #require(try ImageDecoder.decodeAnimation(data: data, formatHint: "gif", boundingSize: (8, 8)))
        #expect(animation.frames.count == 2)
        #expect(animation.durations == [0.1, 0.1])
        #expect(Array(animation.frames[0].pixels[0..<3]) == [255, 255, 255])
        #expect(Array(animation.frames[1].pixels[0..<3]) == [0, 0, 0])
        #expect(try ImageDecoder.decodeAnimation(data: Data([0x89, 0x50]), formatHint: "png", boundingSize: (8, 8)) == nil)
    }

    @Test("Playback picks frames by elapsed time and stops after finite loops")
    func playbackTiming() throws {
        let frames = try (0..<3).map { _ in try ImageAssetRegistry.Asset(image: image(0, width: 1, height: 1)) }
        let looping = AsyncImageAnimation(frames: frames, durations: [0.1, 0.2, 0.1], loopCount: 0)
        #expect(looping.frame(at: 0.05).index == 0)
        #expect(looping.frame(at: 0.15).index == 1)
        #expect(looping.frame(at: 0.35).index == 2)
        #expect(looping.frame(at: 0.45).index == 0)
        let once = AsyncImageAnimation(frames: frames, durations: [0.1, 0.2, 0.1], loopCount: 1)
        #expect(once.frame(at: 0.5) == (2, true))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
