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
    case empty, loading, success(ImageAssetRegistry.Asset), failure(AsyncImageError)
}
final class AsyncImageSession: @unchecked Sendable {
    private let registrar = ObservableStateRegistrar()
    private var request: AsyncImageRequest?
    private var phase: AsyncImageStatus = .empty
    func status(for request: AsyncImageRequest) -> AsyncImageStatus {
        registrar.access("phase")
        return self.request == request ? phase : (request.url == nil ? .empty : .loading)
    }
    func publish(_ phase: AsyncImageStatus, for request: AsyncImageRequest) {
        guard self.request != request || self.phase != phase else { return }
        self.request = request; self.phase = phase
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
        session.publish(.loading, for: request)
        let generation = generation
        task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<DecodedImage, AsyncImageError>
            do {
                let decoded = try await services.decode(request)
                try Task.checkCancellation()
                result = .success(decoded)
            } catch is CancellationError { return }
            catch let error as AsyncImageError { result = .failure(error) }
            catch { result = .failure(.decodeFailed(String(describing: error))) }
            services.enqueue {
                guard let self, self.node != nil, self.generation == generation else { return }
                self.task = nil
                switch result {
                case .success(let decoded):
                    do { session.publish(.success(try services.register(key, decoded)), for: request) }
                    catch { session.publish(.failure(.decodeFailed(String(describing: error))), for: request) }
                case .failure(let error): session.publish(.failure(error), for: request)
                }
            }
        }
    }
}
