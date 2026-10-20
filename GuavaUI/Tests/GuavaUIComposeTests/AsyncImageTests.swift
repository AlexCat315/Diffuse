import Foundation
import Network
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
    @Test("The placeholder initializer shows same-size placeholder content until an image loads")
    func placeholderInitializer() {
        GlobalTestLock.locked {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: AsyncImage(url: nil, width: 40, height: 30) { Box {}.debugName("thumbnail-placeholder") })
            graph.computeLayout(width: 200, height: 200)
            func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
            let placeholder = nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "thumbnail-placeholder" }
            #expect(placeholder?.frame.size == CGSize(width: 40, height: 30))
            graph.install(root: EmptyView())
        }
    }

    @Test("HTTP status, streamed size limits and cancellation use the real transport")
    func httpTransport() async throws {
        let server = try ImageHTTPFixture()
        defer { server.stop() }
        let data = try await ImageDataDownload.load(url: server.url("ok"), policy: .init())
        #expect(data.data == Data("image data".utf8))
        await #expect(throws: AsyncImageError.httpStatus(404)) {
            try await ImageDataDownload.load(url: server.url("missing"), policy: .init())
        }
        var limited = ImageLoadingPolicy(); limited.maximumDownloadBytes = 64
        await #expect(throws: AsyncImageError.downloadTooLarge) {
            try await ImageDataDownload.load(url: server.url("large"), policy: limited)
        }
        let slowURL = server.url("slow")
        let task = Task.detached { try await ImageDataDownload.load(url: slowURL, policy: .init()) }
        try await wait {
            let status = try? await ImageDataDownload.load(url: server.url("slow-started"), policy: .init())
            return status?.data == Data("started".utf8)
        }
        // Main-actor layout suites may delay this test's continuation. Measure
        // transport cancellation on the worker that awaits the held request.
        let cancellation = await Task.detached {
            let start = ContinuousClock.now; task.cancel()
            do {
                _ = try await task.value
                return (cancelled: false, duration: start.duration(to: .now))
            } catch {
                return (cancelled: error is CancellationError, duration: start.duration(to: .now))
            }
        }.value
        #expect(cancellation.cancelled)
        #expect(cancellation.duration < .seconds(1))
    }
    @Test("Missing local files expose a bounded error instead of a Foundation debug dump")
    func missingFile() async {
        await #expect(throws: AsyncImageError.fileNotFound) {
            try await ImageDataDownload.load(url: URL(fileURLWithPath: "/guava-image-test-\(UUID()).png"), policy: .init())
        }
    }
    @Test("Response MIME and redirected URLs select the SVG decoder through the production image service",
          arguments: ["vector", "vector.jpg", "fallback.svg", "redirect"])
    func remoteVector(path: String) async throws {
        let server = try ImageHTTPFixture()
        defer { server.stop() }
        let (services, request) = try GlobalTestLock.locked {
            let registry = ImageAssetRegistryHolder.current, enqueue = UIWorkSchedulerHolder.enqueue
            let density = ContentScaleHolder.current
            defer {
                ImageAssetRegistryHolder.current = registry; UIWorkSchedulerHolder.enqueue = enqueue
                ContentScaleHolder.current = density
            }
            ImageAssetRegistryHolder.current = ImageAssetRegistry()
            UIWorkSchedulerHolder.enqueue = { _ in }
            ContentScaleHolder.current = 1
            return (try #require(ImageLoadServices.current), AsyncImageRequest(url: server.url(path),
                width: 80, height: 80, mode: .fit, retryID: 0, policy: .init()))
        }
        let payload = try await services.decode(request, { _ in })
        guard case .still(let image) = payload else { Issue.record("Expected a still SVG thumbnail"); return }
        #expect(image.width == 80 && image.height == 40)
        #expect(image.pixels[0..<4].elementsEqual([255, 0, 0, 255]))
    }
    @Test("Missing or generic MIME keeps local and remote extension hints")
    func formatFallbacks() {
        let url = URL(string: "https://image.test/vector.SVG?download=1")!
        #expect(DownloadedImage(data: Data(), url: url).formatHint == "svg")
        #expect(DownloadedImage(data: Data(), url: url, mimeType: "application/octet-stream").formatHint == "svg")
        #expect(DownloadedImage(data: Data(), url: url, mimeType: " Image/PNG ; charset=binary").formatHint == "png")
    }
    private func request(_ path: String, retryID: Int = 0) -> AsyncImageRequest {
        .init(url: URL(string: "https://image.test/\(path).png"), width: 48, height: 48, mode: .fill, retryID: retryID, policy: .init())
    }
    private func makeServices(gate: ImageDecodeGate, ui: ImageTestUIQueue) -> ImageLoadServices {
        .init(id: "test-images", cached: { _ in nil }, decode: { request, _ in .still(try await gate.decode(request)) },
              register: { _, decoded in
                  #expect(Thread.isMainThread)
                  ui.registrations += 1
                  let asset = try ImageAssetRegistry.Asset(image: decoded)
                  ui.asset = asset
                  return asset
              }, enqueue: ui.enqueue)
    }
    @concurrent
    private nonisolated func wait(_ condition: @Sendable () async -> Bool) async throws {
        // Sample worker readiness on a concurrent executor. Synchronous layout
        // suites can occupy the main actor longer than this deadline; that
        // must not delay the next predicate check or manufacture a timeout.
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
    private let server: ImageHTTPServer
    init() throws { server = try ImageHTTPServer() }
    func url(_ path: String) -> URL { server.url(path) }
    func stop() { server.stop() }
}

/// A minimal localhost HTTP server so the transport test exercises real sockets
/// instead of a mock. It serves `/ok`, `/missing`, `/large`, a held `/slow`
/// request and the `/slow-started` probe that reports when `/slow` arrived.
private final class ImageHTTPServer: @unchecked Sendable {
    private(set) var port = 0
    private let listener: NWListener
    private let lock = NSLock()
    private var slowStarted = false
    private var held: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            throw AsyncImageError.networkFailed("HTTP fixture did not start")
        }
        self.port = Int(port)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }

    func stop() {
        listener.cancel()
        let connections = lock.withLock { let value = held; held = []; return value }
        connections.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let target = request.split(separator: " ").dropFirst().first else {
                connection.cancel(); return
            }
            let path = String(target.split(separator: "?").first ?? target)
            switch path {
            case "/slow":
                // Held open until the client cancels; the connection must stay retained.
                self.lock.withLock { self.slowStarted = true; self.held.append(connection) }
            case "/slow-started":
                let started = self.lock.withLock { self.slowStarted }
                self.respond(connection, status: 200, body: Data((started ? "started" : "pending").utf8))
            case "/missing":
                self.respond(connection, status: 404, body: Data())
            case "/large":
                self.respond(connection, status: 200, body: Data(repeating: UInt8(ascii: "x"), count: 2048))
            case "/vector", "/vector.jpg", "/fallback.svg":
                let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"80\"><rect width=\"160\" height=\"80\" fill=\"red\"/></svg>".utf8)
                self.respond(connection, status: 200, body: svg, headers: [
                    "Content-Type": path == "/fallback.svg" ? "application/octet-stream" : "image/svg+xml; charset=utf-8"
                ])
            case "/redirect":
                self.respond(connection, status: 302, body: Data(), headers: ["Location": self.url("fallback.svg").absoluteString])
            default:
                self.respond(connection, status: 200, body: Data("image data".utf8))
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data, headers: [String: String] = [:]) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
