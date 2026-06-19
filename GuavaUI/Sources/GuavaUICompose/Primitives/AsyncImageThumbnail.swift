import GuavaUIRuntime

/// Non-blocking image preview for editor thumbnails.
///
/// The first frame renders a caller-provided placeholder immediately. Decode
/// work happens off the UI loop at the requested thumbnail size, then texture
/// upload is handed back to the host UI loop before the view refreshes.
public struct AsyncImageThumbnail<Placeholder: View>: View {
    public let path: String
    public let width: Float
    public let height: Float
    public let isEnabled: Bool
    public let placeholder: Placeholder
    @State private var phase: AsyncImageThumbnailPhase = .idle

    public init(path: String,
                width: Float,
                height: Float,
                isEnabled: Bool = true,
                @ViewBuilder placeholder: () -> Placeholder) {
        self.path = path
        self.width = width
        self.height = height
        self.isEnabled = isEnabled
        self.placeholder = placeholder()
    }

    public var body: some View {
        let request = AsyncImageThumbnailRequest(path: path, width: width, height: height)
        if let cached = cachedAsset(for: request) {
            return AnyView(image(asset: cached))
        }

        scheduleLoadIfNeeded(request)
        if case let .ready(key, textureID, sourceWidth, sourceHeight) = phase,
           key == request.key {
            return AnyView(
                image(textureID: textureID,
                      sourceWidth: sourceWidth,
                      sourceHeight: sourceHeight)
            )
        }
        return AnyView(placeholderFrame)
    }

    private var placeholderFrame: some View {
        placeholder
            .opacity(isEnabled ? 1 : 0.55)
            .frame(width: width, height: height)
    }

    private func image(asset: ImageAssetRegistry.Asset) -> some View {
        image(textureID: asset.textureID,
              sourceWidth: Float(asset.width),
              sourceHeight: Float(asset.height))
    }

    private func image(textureID: TextureID,
                       sourceWidth: Float,
                       sourceHeight: Float) -> some View {
        Image(textureID: textureID,
              width: width,
              height: height,
              sourcePixelSize: (sourceWidth, sourceHeight),
              contentMode: .fit)
            .frame(width: width, height: height)
            .opacity(isEnabled ? 1 : 0.55)
            .clipped()
    }

    private func cachedAsset(for request: AsyncImageThumbnailRequest) -> ImageAssetRegistry.Asset? {
        ImageAssetRegistryHolder.current?.cached(request.key)
    }

    private func scheduleLoadIfNeeded(_ request: AsyncImageThumbnailRequest) {
        guard !phase.isCurrent(for: request.key),
              let registry = ImageAssetRegistryHolder.current,
              UIWorkSchedulerHolder.enqueue != nil
        else { return }

        phase = .loading(request.key)
        let stateSink = AsyncImageThumbnailStateSink(
            get: { phase },
            set: { phase = $0 }
        )
        Task.detached(priority: .utility) {
            let decoded: DecodedImage
            do {
                decoded = try ImageDecoder.decode(url: request.url,
                                                  targetSize: request.pixelSize)
            } catch {
                UIWorkSchedulerHolder.schedule {
                    if stateSink.phase == .loading(request.key) {
                        stateSink.phase = .failed(request.key)
                    }
                }
                return
            }

            AsyncImageThumbnailUploadQueue.shared.enqueue {
                guard stateSink.phase == .loading(request.key) else { return }
                do {
                    let asset = try registry.register(key: request.key, decoded: decoded)
                    stateSink.phase = .ready(key: request.key,
                                             textureID: asset.textureID,
                                             sourceWidth: Float(asset.width),
                                             sourceHeight: Float(asset.height))
                } catch {
                    stateSink.phase = .failed(request.key)
                }
            }
        }
    }
}

private final class AsyncImageThumbnailUploadQueue: @unchecked Sendable {
    static let shared = AsyncImageThumbnailUploadQueue()

    private let lock = NSLock()
    private var uploads: [() -> Void] = []
    private var headIndex = 0
    private var isScheduled = false

    func enqueue(_ upload: @escaping () -> Void) {
        lock.lock()
        uploads.append(upload)
        let shouldSchedule = !isScheduled
        if shouldSchedule {
            isScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            scheduleNextDrain()
        }
    }

    private func scheduleNextDrain() {
        UIWorkSchedulerHolder.schedule { [weak self] in
            self?.drainOne()
        }
    }

    private func drainOne() {
        lock.lock()
        let upload: (() -> Void)?
        if headIndex < uploads.count {
            upload = uploads[headIndex]
            headIndex += 1
        } else {
            upload = nil
        }
        let hasMore = headIndex < uploads.count
        if !hasMore {
            uploads.removeAll(keepingCapacity: true)
            headIndex = 0
            isScheduled = false
        }
        lock.unlock()

        upload?()

        if hasMore {
            scheduleNextDrain()
        }
    }
}

private final class AsyncImageThumbnailStateSink: @unchecked Sendable {
    private let get: () -> AsyncImageThumbnailPhase
    private let set: (AsyncImageThumbnailPhase) -> Void

    init(get: @escaping () -> AsyncImageThumbnailPhase,
         set: @escaping (AsyncImageThumbnailPhase) -> Void) {
        self.get = get
        self.set = set
    }

    var phase: AsyncImageThumbnailPhase {
        get { get() }
        set { set(newValue) }
    }
}

private struct AsyncImageThumbnailRequest: Sendable {
    let path: String
    let pixelSize: (width: Int, height: Int)
    let key: String

    init(path: String, width: Float, height: Float) {
        self.path = path
        let scale = max(1, ContentScaleHolder.current)
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        self.pixelSize = (pixelWidth, pixelHeight)
        self.key = ImageAssetRegistry.key(for: URL(fileURLWithPath: path),
                                          size: (pixelWidth, pixelHeight))
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

private enum AsyncImageThumbnailPhase: Sendable, Equatable {
    case idle
    case loading(String)
    case ready(key: String, textureID: TextureID, sourceWidth: Float, sourceHeight: Float)
    case failed(String)

    func isCurrent(for key: String) -> Bool {
        switch self {
        case .idle:
            return false
        case .loading(let current), .failed(let current):
            return current == key
        case .ready(let current, _, _, _):
            return current == key
        }
    }
}
