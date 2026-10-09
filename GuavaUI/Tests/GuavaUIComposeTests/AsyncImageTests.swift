import Foundation
import Testing
@testable import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Asynchronous image lifecycle", .serialized)
@MainActor
struct AsyncImageTests {
    @Test("Changing source drops old replies and registers CPU assets only on the captured UI queue")
    func sourceReplacement() async throws {
        let gate = ImageDecodeGate(), ui = ImageTestUIQueue()
        let services = makeServices(gate: gate, ui: ui)
        let resource = AsyncImageResource(), session = AsyncImageSession(), node = Node()
        resource.mount(node: node)
        let first = request("first"), second = request("second")
        resource.configure(session: session, request: first, services: services)
        try await wait { await gate.contains(first) }
        resource.configure(session: session, request: second, services: services)
        try await wait { await gate.contains(second) }
        await gate.finish(second)
        try await wait { ui.count > 0 }
        #expect(ui.registrations == 0)
        ui.drain()
        #expect(ui.registrations == 1)
        #expect(session.status(for: second) == .success(try #require(ui.asset)))
        await gate.finish(first)
        try await Task.sleep(for: .milliseconds(50))
        ui.drain()
        #expect(ui.registrations == 1)
        #expect(session.status(for: second) == .success(try #require(ui.asset)))
        resource.unmount(node: node)
    }
    @Test("Unmount cancels registration and publishing even if decode already completed")
    func unmountBeforeRegistration() async throws {
        let gate = ImageDecodeGate(), ui = ImageTestUIQueue()
        let resource = AsyncImageResource(), session = AsyncImageSession(), node = Node()
        resource.mount(node: node)
        let request = request("unmount")
        resource.configure(session: session, request: request, services: makeServices(gate: gate, ui: ui))
        try await wait { await gate.contains(request) }
        await gate.finish(request)
        try await wait { ui.count > 0 }
        resource.unmount(node: node)
        ui.drain()
        #expect(ui.registrations == 0)
        #expect(session.status(for: request) == .loading)
    }
    @Test("A drawable density change replaces an existing request without rebuilding the node")
    func densityReplacement() async throws {
        let gate = ImageDecodeGate(), ui = ImageTestUIQueue()
        let services = makeServices(gate: gate, ui: ui)
        let resource = AsyncImageResource(), session = AsyncImageSession(), node = Node()
        resource.mount(node: node)
        let first = GlobalTestLock.locked {
            let scale = ContentScaleHolder.current; defer { ContentScaleHolder.current = scale }
            ContentScaleHolder.current = 1; return request("density")
        }
        resource.configure(session: session, request: first, services: services)
        try await wait { await gate.contains(first) }
        let second = GlobalTestLock.locked {
            let scale = ContentScaleHolder.current; defer { ContentScaleHolder.current = scale }
            ContentScaleHolder.current = 2
            resource.refreshDensity(session: session, original: first, services: services)
            return request("density")
        }
        #expect(second.pixelWidth == first.pixelWidth * 2)
        try await wait { await gate.contains(second) }
        await gate.finish(first)
        await gate.finish(second)
        try await wait { ui.count > 0 }; ui.drain()
        #expect(ui.registrations == 1)
        #expect(session.status(for: second) == .success(try #require(ui.asset)))
        resource.unmount(node: node)
    }
    @Test("A failed request stays settled until its retry identity changes")
    func explicitRetry() async throws {
        let gate = ImageDecodeGate(), ui = ImageTestUIQueue()
        let services = makeServices(gate: gate, ui: ui)
        let resource = AsyncImageResource(), session = AsyncImageSession(), node = Node()
        resource.mount(node: node)
        let first = request("retry")
        resource.configure(session: session, request: first, services: services)
        try await wait { await gate.contains(first) }
        await gate.finish(first, failure: .httpStatus(404))
        try await wait { ui.count > 0 }; ui.drain()
        #expect(session.status(for: first) == .failure(.httpStatus(404)))
        resource.configure(session: session, request: first, services: services)
        #expect(await gate.startCount == 1)
        let retry = request("retry", retryID: 1)
        resource.configure(session: session, request: retry, services: services)
        try await wait { await gate.contains(retry) }
        await gate.finish(retry)
        try await wait { ui.count > 0 }; ui.drain()
        let starts = await gate.startCount
        #expect(ui.registrations == 1 && starts == 2)
        resource.unmount(node: node)
    }
    @Test("Remote cache keys distinguish host and query; render size and policy are bounded")
    func cacheIdentityAndBounds() {
        let urls = ["https://one.test/avatar.png?v=1", "https://one.test/avatar.png?v=2", "https://two.test/avatar.png?v=1"]
        #expect(Set(urls.map { ImageAssetRegistry.key(for: URL(string: $0)!, size: (48, 48)) }).count == 3)
        let image = AsyncImage(url: nil, width: .nan, height: .infinity, configure: {
            $0.timeout = .nan; $0.maximumDownloadBytes = -1; $0.maximumSourcePixels = 0
        }) { _ in EmptyView() }
        #expect(image.width == 32 && image.height == 32)
        #expect(image.policy.timeout == 15 && image.policy.maximumDownloadBytes == 1 && image.policy.maximumSourcePixels == 1)
    }
    @Test("HTTP status, streamed size limits and cancellation use the real transport")
    func httpTransport() async throws {
        let server = try ImageHTTPFixture()
        defer { server.stop() }
        let data = try await ImageDataDownload.load(url: server.url("ok"), policy: .init())
        #expect(data == Data("image data".utf8))
        await #expect(throws: AsyncImageError.httpStatus(404)) {
            try await ImageDataDownload.load(url: server.url("missing"), policy: .init())
        }
        var limited = ImageLoadingPolicy(); limited.maximumDownloadBytes = 64
        await #expect(throws: AsyncImageError.downloadTooLarge) {
            try await ImageDataDownload.load(url: server.url("large"), policy: limited)
        }
        let task = Task { try await ImageDataDownload.load(url: server.url("slow"), policy: .init()) }
        try await Task.sleep(for: .milliseconds(80))
        let start = ContinuousClock.now; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
    }
    @Test("Missing local files expose a bounded error instead of a Foundation debug dump")
    func missingFile() async {
        await #expect(throws: AsyncImageError.fileNotFound) {
            try await ImageDataDownload.load(url: URL(fileURLWithPath: "/guava-image-test-\(UUID()).png"), policy: .init())
        }
    }
    private func request(_ path: String, retryID: Int = 0) -> AsyncImageRequest {
        .init(url: URL(string: "https://image.test/\(path).png"), width: 48, height: 48, mode: .fill, retryID: retryID, policy: .init())
    }
    private func makeServices(gate: ImageDecodeGate, ui: ImageTestUIQueue) -> ImageLoadServices {
        .init(id: "test-images", cached: { _ in nil }, decode: { try await gate.decode($0) },
              register: { _, decoded in
                  #expect(Thread.isMainThread)
                  ui.registrations += 1
                  let asset = try ImageAssetRegistry.Asset(image: decoded)
                  ui.asset = asset
                  return asset
              }, enqueue: ui.enqueue)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        // Other Compose suites perform synchronous layout on the main actor.
        // This is a correctness wait, not a latency benchmark; allow those
        // suites to finish before treating a pending worker as a failure.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("Image task did not settle"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
private actor ImageDecodeGate {
    private var pending: [String: CheckedContinuation<DecodedImage, Error>] = [:]
    private(set) var startCount = 0
    private func key(_ request: AsyncImageRequest) -> String { "\(request.url!.absoluteString)#\(request.retryID)#\(request.pixelWidth)x\(request.pixelHeight)" }
    func contains(_ request: AsyncImageRequest) -> Bool { pending[key(request)] != nil }
    func decode(_ request: AsyncImageRequest) async throws -> DecodedImage {
        startCount += 1
        return try await withCheckedThrowingContinuation { pending[key(request)] = $0 }
    }
    func finish(_ request: AsyncImageRequest, failure: AsyncImageError? = nil) {
        let continuation = pending.removeValue(forKey: key(request))
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: .init(pixels: [255, 0, 0, 255, 0, 255, 0, 255], width: 2, height: 1)) }
    }
}
private final class ImageTestUIQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    var registrations = 0
    var asset: ImageAssetRegistry.Asset?
    var count: Int { lock.withLock { jobs.count } }
    func enqueue(_ work: @escaping () -> Void) { lock.withLock { jobs.append(work) } }
    func drain() { let jobs = lock.withLock { let result = self.jobs; self.jobs = []; return result }; jobs.forEach { $0() } }
}
private struct ImageHTTPFixture {
    let process: Process
    let port: Int
    init() throws {
        process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.program]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        port = Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    func stop() { if process.isRunning { process.terminate() } }
    private static let program = #"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import time
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/slow': time.sleep(2)
        self.send_response(404 if self.path == '/missing' else 200)
        self.end_headers()
        try: self.wfile.write(b'x' * 2048 if self.path == '/large' else b'image data')
        except BrokenPipeError: pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#
}
