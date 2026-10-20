import Foundation
import GuavaUIRuntime

public struct ImageLoadingPolicy: Sendable, Equatable {
    public var timeout: Double = 15
    public var maximumDownloadBytes = 20 * 1_024 * 1_024
    public var maximumSourcePixels = 32_000_000
    public init() {}
    mutating func validate() {
        timeout = timeout.isFinite ? max(0.1, timeout) : 15
        maximumDownloadBytes = max(1, maximumDownloadBytes)
        maximumSourcePixels = max(1, maximumSourcePixels)
    }
}

public enum AsyncImageError: Error, Sendable, Equatable, CustomStringConvertible {
    case hostUnavailable, unsupportedURL, invalidResponse, fileNotFound, fileReadFailed
    case httpStatus(Int), downloadTooLarge, decodeFailed(String), networkFailed(String)
    public var description: String {
        switch self {
        case .hostUnavailable: "Image host unavailable"
        case .unsupportedURL: "Unsupported image URL"
        case .invalidResponse: "Invalid image response"
        case .fileNotFound: "Image file not found"
        case .fileReadFailed: "Could not read image file"
        case .httpStatus(let code): "Image request returned HTTP \(code)"
        case .downloadTooLarge: "Image exceeds the download limit"
        case .decodeFailed(let message): "Could not decode image: \(message)"
        case .networkFailed(let message): "Could not load image: \(message)"
        }
    }
}

public enum AsyncImagePhase {
    case empty
    case loading
    case success(Image)
    case failure(AsyncImageError)
}

/// File or HTTP image with explicit loading/failure content. Decode is off the
/// UI loop; registration and publication use the captured host scheduler. The node
/// owns cancellation, so an old request cannot replace a newer source.
public struct AsyncImage<Content: View>: View {
    public let url: URL?
    public let width: Float
    public let height: Float
    public let contentMode: Image.ContentMode
    public let retryID: Int
    public var policy = ImageLoadingPolicy()
    private let content: (AsyncImagePhase) -> Content
    @State private var session = AsyncImageSession()

    public init(url: URL?, width: Float, height: Float, contentMode: Image.ContentMode = .fit,
                retryID: Int = 0, configure: (inout ImageLoadingPolicy) -> Void = { _ in },
                @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.width = width.isFinite ? max(1, min(4_096, width)) : 32
        self.height = height.isFinite ? max(1, min(4_096, height)) : 32
        self.contentMode = contentMode; self.retryID = retryID
        self.content = content; configure(&policy); policy.validate()
    }

    public var body: some View {
        let request = AsyncImageRequest(url: url, width: width, height: height, mode: contentMode,
                                        retryID: retryID, policy: policy)
        let phase: AsyncImagePhase
        switch session.status(for: request) {
        case .empty: phase = .empty
        case .loading: phase = .loading
        case .success(let asset):
            phase = .success(Image(source: .asset(asset), width: width, height: height, contentMode: contentMode))
        case .animated(let animation):
            phase = .success(Image(source: .asset(animation.frames[min(animation.frames.count - 1, session.frameIndex)]),
                                   width: width, height: height, contentMode: contentMode))
        case .failure(let error): phase = .failure(error)
        }
        return AsyncImageHost(session: session, request: request, content: content(phase))
    }
}

struct AsyncImageRequest: Sendable, Equatable {
    let url: URL?
    let width: Float
    let height: Float
    let pixelWidth: Int
    let pixelHeight: Int
    let mode: Image.ContentMode
    let retryID: Int
    let policy: ImageLoadingPolicy
    init(url: URL?, width: Float, height: Float, mode: Image.ContentMode, retryID: Int, policy: ImageLoadingPolicy) {
        self.url = url; self.width = width; self.height = height; self.mode = mode
        self.retryID = retryID
        var policy = policy; policy.validate(); self.policy = policy
        let density = ContentScaleHolder.current
        let scale = density.isFinite ? max(1, min(8, density)) : 1
        // Fill uses a larger aspect-preserving thumbnail before central crop.
        let oversample: Float = mode == .fill ? 2 : 1
        pixelWidth = max(1, min(8_192, Int((width * scale * oversample).rounded())))
        pixelHeight = max(1, min(8_192, Int((height * scale * oversample).rounded())))
    }
    var cacheKey: String? { url.map { ImageAssetRegistry.key(for: $0, size: (pixelWidth, pixelHeight)) + "#aspect-thumbnail" } }
}

enum AsyncImageStatus: Equatable {
    case empty, loading, success(ImageAssetRegistry.Asset), animated(AsyncImageAnimation), failure(AsyncImageError)
    var isLoading: Bool { if case .loading = self { true } else { false } }
}

/// Registered frames of one animated image. Identity equality: a new decode
/// is a new animation even when its pixels match.
final class AsyncImageAnimation: Equatable, @unchecked Sendable {
    let frames: [ImageAssetRegistry.Asset]
    let durations: [Double]
    let loopCount: Int
    init(frames: [ImageAssetRegistry.Asset], durations: [Double], loopCount: Int) {
        self.frames = frames; self.durations = durations; self.loopCount = loopCount
    }
    static func == (lhs: AsyncImageAnimation, rhs: AsyncImageAnimation) -> Bool { lhs === rhs }

    /// Frame shown `elapsed` seconds into playback, holding the last frame
    /// once a finite loop count is exhausted.
    func frame(at elapsed: Double) -> (index: Int, isFinished: Bool) {
        let cycle = durations.reduce(0, +)
        guard frames.count > 1, cycle > 0 else { return (0, true) }
        if loopCount > 0, elapsed >= cycle * Double(loopCount) { return (frames.count - 1, true) }
        var remaining = elapsed.truncatingRemainder(dividingBy: cycle)
        for (index, duration) in durations.enumerated() {
            if remaining < duration { return (index, false) }
            remaining -= duration
        }
        return (frames.count - 1, false)
    }
}

/// Remembers decoded animations by cache key so remounting a row plays again
/// without a download. Small and least-recently-used; frames also count
/// against the registry budget.
final class AsyncImageAnimationCache: @unchecked Sendable {
    static let shared = AsyncImageAnimationCache()
    private let lock = NSLock()
    private var entries: [String: (animation: AsyncImageAnimation, use: UInt64)] = [:]
    private var clock: UInt64 = 0
    private let capacity = 64
    func value(_ key: String) -> AsyncImageAnimation? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            clock &+= 1; entries[key] = (entry.animation, clock); return entry.animation
        }
    }
    func store(_ animation: AsyncImageAnimation, for key: String) {
        lock.withLock {
            clock &+= 1; entries[key] = (animation, clock)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.use < $1.value.use })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }
}
final class AsyncImageSession: @unchecked Sendable {
    private let registrar = ObservableStateRegistrar()
    private var request: AsyncImageRequest?
    private var phase: AsyncImageStatus = .empty
    private var frame = 0
    /// Current animation frame; playback writes it, the body reads it.
    var frameIndex: Int {
        get { registrar.access("frame"); return frame }
        set { guard frame != newValue else { return }; frame = newValue; registrar.invalidate("frame") }
    }
    /// The animation published for the current request, read without tracking.
    var animation: AsyncImageAnimation? { if case .animated(let animation) = phase { animation } else { nil } }
    private var isPreview = false
    func isPreviewing(_ request: AsyncImageRequest) -> Bool { self.request == request && isPreview }
    /// A progressive preview: shown like a success, replaced by the final result.
    func publishPreview(_ asset: ImageAssetRegistry.Asset, for request: AsyncImageRequest) {
        self.request = request; phase = .success(asset); isPreview = true
        registrar.invalidate("phase")
    }
    func status(for request: AsyncImageRequest) -> AsyncImageStatus {
        registrar.access("phase")
        return self.request == request ? phase : (request.url == nil ? .empty : .loading)
    }
    func publish(_ phase: AsyncImageStatus, for request: AsyncImageRequest) {
        guard self.request != request || self.phase != phase else { return }
        if case .animated = phase, self.phase != phase { frame = 0 }
        self.request = request; self.phase = phase; isPreview = false
        registrar.invalidate("phase")
    }
}

private struct AsyncImageHost<Content: View>: _PrimitiveView {
    let session: AsyncImageSession
    let request: AsyncImageRequest
    let content: Content
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false
        node.addResource(AsyncImageResource())
        node.addResource(AsyncImagePlayback())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.width = request.width; layout.height = request.height
        layout.alignItems = .center; layout.justifyContent = .center
        return layout
    }
    func _updateLayout(_ layout: LayoutNode) { layout.width = request.width; layout.height = request.height }
    func _updateNode(_ node: Node) {
        let resource = node.firstResource(AsyncImageResource.self)
        resource?.configure(session: session, request: request)
        node.firstResource(AsyncImagePlayback.self)?.configure(
            session: session, reducedMotion: node.compositionValue(of: ReducedMotionEnvironment.key))
        let session = session, request = request
        node.updateDraw(identity: request) { [weak resource] _, _ in
            resource?.refreshDensity(session: session, original: request)
        }
    }
    var _children: [any View] { [content] }
}

final class AsyncImageResource: NodeResource, @unchecked Sendable {
    private weak var node: Node?
    private var request: AsyncImageRequest?
    private var servicesID: AnyHashable?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func mount(node: Node) { self.node = node }
    func unmount(node: Node) { cancel(); self.node = nil }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; request = nil }
    func refreshDensity(session: AsyncImageSession, original: AsyncImageRequest, services: ImageLoadServices? = nil) {
        let scaled = AsyncImageRequest(url: original.url, width: original.width, height: original.height,
            mode: original.mode, retryID: original.retryID, policy: original.policy)
        guard request != scaled else { return }
        configure(session: session, request: scaled, services: services ?? ImageLoadServices.current)
    }
    func configure(session: AsyncImageSession, request: AsyncImageRequest,
                   services: ImageLoadServices? = ImageLoadServices.current) {
        guard self.request != request || self.servicesID != services?.id else { return }
        cancel(); self.request = request; self.servicesID = services?.id
        guard let key = request.cacheKey, request.url != nil else { session.publish(.empty, for: request); return }
        guard let services else {
            session.publish(.failure(.hostUnavailable), for: request); return
        }
        if let asset = services.cached(key) { session.publish(.success(asset), for: request); return }
        if let animation = AsyncImageAnimationCache.shared.value(key) { session.publish(.animated(animation), for: request); return }
        session.publish(.loading, for: request)
        let generation = generation
        // Previews of a progressive image show until the final decode lands.
        let preview: ImageProgress = { [weak self] image in
            services.enqueue {
                guard let self, self.node != nil, self.generation == generation,
                      session.status(for: request).isLoading || session.isPreviewing(request),
                      let asset = try? ImageAssetRegistry.Asset(image: image) else { return }
                session.publishPreview(asset, for: request)
            }
        }
        let sharedKey = "\(services.id)|\(key)|\(request.retryID)"
        task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<ImagePayload, AsyncImageError>
            do {
                let decoded = try await ImageInflightLoads.shared.load(key: sharedKey, progress: preview) { progress in
                    try await services.decode(request, progress)
                }
                try Task.checkCancellation()
                result = .success(decoded)
            } catch is CancellationError { return }
            catch let error as AsyncImageError { result = .failure(error) }
            catch { result = .failure(.decodeFailed(String(describing: error))) }
            services.enqueue {
                guard let self, self.node != nil, self.generation == generation else { return }
                self.task = nil
                switch result {
                case .success(.still(let decoded)):
                    do { session.publish(.success(try services.register(key, decoded)), for: request) }
                    catch { session.publish(.failure(.decodeFailed(String(describing: error))), for: request) }
                case .success(.animation(let decoded)):
                    do {
                        let frames = try decoded.frames.enumerated().map { try services.register("\(key)#frame-\($0.offset)", $0.element) }
                        let animation = AsyncImageAnimation(frames: frames, durations: decoded.durations, loopCount: decoded.loopCount)
                        AsyncImageAnimationCache.shared.store(animation, for: key)
                        session.publish(.animated(animation), for: request)
                    } catch { session.publish(.failure(.decodeFailed(String(describing: error))), for: request) }
                case .failure(let error): session.publish(.failure(error), for: request)
                }
            }
        }
    }
}

public extension AsyncImage where Content == AnyView {
    /// Shows the loaded image, or `placeholder` at the same size while it is
    /// empty, loading or failed.
    init<Placeholder: View>(url: URL?, width: Float, height: Float, contentMode: Image.ContentMode = .fit,
                            @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.init(url: url, width: width, height: height, contentMode: contentMode) { phase in
            if case .success(let image) = phase { return AnyView(image) }
            return AnyView(placeholder().frame(width: width, height: height))
        }
    }
}

/// Plays an animated image on the shared animation scheduler. Reduced
/// motion shows the first frame; a finite loop count ends on the last frame.
final class AsyncImagePlayback: NodeResource, AnyAnimationController, @unchecked Sendable {
    private weak var scheduler: AnimatorScheduler?
    private weak var session: AsyncImageSession?
    private var animation: AsyncImageAnimation?
    private var elapsed = 0.0
    private(set) var isFinished = true

    func mount(node: Node) { scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { cancel(); scheduler = nil }

    func configure(session: AsyncImageSession, reducedMotion: Bool) {
        let next = reducedMotion ? nil : session.animation
        guard next !== animation || self.session !== session else { return }
        cancel()
        self.session = session; animation = next
        guard next != nil else { return }
        elapsed = 0; isFinished = false
        scheduler?.register(self)
    }

    func tick(deltaTime: Double) {
        guard !isFinished, let animation else { return }
        elapsed += max(0, deltaTime)
        let frame = animation.frame(at: elapsed)
        session?.frameIndex = frame.index
        if frame.isFinished { isFinished = true }
    }

    func finishImmediately() { cancel() }
    func cancel() { isFinished = true; animation = nil }
}
