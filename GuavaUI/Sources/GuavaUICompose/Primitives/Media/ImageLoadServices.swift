import Foundation
import GuavaUIRuntime

/// A decoded still image or every frame of an animation.
enum ImagePayload: Sendable {
    case still(DecodedImage)
    case animation(DecodedAnimation)
}

/// Receives low-resolution previews while a progressive image downloads.
typealias ImageProgress = @Sendable (DecodedImage) -> Void

/// Boundary between node lifecycle, background decode and UI-thread publication.
final class ImageLoadServices: @unchecked Sendable {
    let id: AnyHashable
    let cached: (String) -> ImageAssetRegistry.Asset?
    let decode: @Sendable (AsyncImageRequest, @escaping ImageProgress) async throws -> ImagePayload
    let register: (String, DecodedImage) throws -> ImageAssetRegistry.Asset
    let enqueue: (@escaping () -> Void) -> Void
    init(id: AnyHashable, cached: @escaping (String) -> ImageAssetRegistry.Asset?,
         decode: @escaping @Sendable (AsyncImageRequest, @escaping ImageProgress) async throws -> ImagePayload,
         register: @escaping (String, DecodedImage) throws -> ImageAssetRegistry.Asset,
         enqueue: @escaping (@escaping () -> Void) -> Void) {
        self.id = id; self.cached = cached; self.decode = decode; self.register = register; self.enqueue = enqueue
    }
    static var current: ImageLoadServices? {
        guard let registry = ImageAssetRegistryHolder.current, let enqueue = UIWorkSchedulerHolder.enqueue else { return nil }
        return ImageLoadServices(id: ObjectIdentifier(registry), cached: registry.cached, decode: { request, preview in
            guard let url = request.url else { throw AsyncImageError.unsupportedURL }
            let bounds = (request.pixelWidth, request.pixelHeight)
            let data = try await ImageDataDownload.load(url: url, policy: request.policy) { partial in
                if let image = ImageDecoder.decodePartial(data: partial, boundingSize: bounds) { preview(image) }
            }
            try Task.checkCancellation()
            let hint = url.pathExtension.lowercased()
            if let animation = try ImageDecoder.decodeAnimation(data: data, formatHint: hint, boundingSize: bounds,
                                                                maximumSourcePixels: request.policy.maximumSourcePixels) {
                return .animation(animation)
            }
            return .still(try ImageDecoder.decodeThumbnail(data: data, formatHint: hint,
                boundingSize: bounds, maximumSourcePixels: request.policy.maximumSourcePixels))
        }, register: { try registry.register(key: $0, decoded: $1) }, enqueue: { work in
            ImagePublicationQueue.shared.enqueue(work, scheduler: enqueue)
        })
    }
}

/// Keep a folder of thumbnails from publishing all completed images in one
/// run-loop batch. Every queued publication retains its own host scheduler.
private final class ImagePublicationQueue: @unchecked Sendable {
    static let shared = ImagePublicationQueue()
    private struct Job {
        let work: () -> Void
        let scheduler: (@escaping () -> Void) -> Void
    }
    private let lock = NSLock()
    private var jobs: [Job] = []
    private var head = 0
    private var isScheduled = false
    func enqueue(_ work: @escaping () -> Void, scheduler: @escaping (@escaping () -> Void) -> Void) {
        let schedule = lock.withLock { () -> Bool in
            jobs.append(Job(work: work, scheduler: scheduler))
            let needsSchedule = !isScheduled; isScheduled = true; return needsSchedule
        }
        if schedule { scheduler { [weak self] in self?.drain() } }
    }
    private func drain() {
        let job = lock.withLock { () -> Job? in
            guard head < jobs.count else { return nil }
            let job = jobs[head]; head += 1; return job
        }
        job?.work()
        let next = lock.withLock { () -> Job? in
            if head == jobs.count { jobs.removeAll(keepingCapacity: true); head = 0; isScheduled = false; return nil }
            return jobs[head]
        }
        next?.scheduler { [weak self] in self?.drain() }
    }
}

/// One download and decode per cache key, shared by every node that asks for
/// it while it is in flight. Each waiter keeps its own cancellation; the
/// shared work stops only when its last waiter leaves. A finished load leaves
/// the table, so later requests hit the asset cache or start afresh.
final class ImageInflightLoads: @unchecked Sendable {
    static let shared = ImageInflightLoads()

    private final class Load: @unchecked Sendable {
        var task: Task<ImagePayload, Error>?
        var waiters: [UUID: ImageProgress] = [:]
        var preview: DecodedImage?
    }
    private let lock = NSLock()
    private var loads: [String: Load] = [:]

    var activeCount: Int { lock.withLock { loads.count } }

    func load(key: String, progress: @escaping ImageProgress,
              start: @escaping @Sendable (@escaping ImageProgress) async throws -> ImagePayload) async throws -> ImagePayload {
        let token = UUID()
        let (load, preview): (Load, DecodedImage?) = lock.withLock {
            if let existing = loads[key] {
                existing.waiters[token] = progress
                return (existing, existing.preview)
            }
            let load = Load()
            load.waiters[token] = progress
            loads[key] = load
            load.task = Task.detached(priority: .utility) {
                defer { self.finish(key, load) }
                return try await start { image in self.broadcast(image, from: load) }
            }
            return (load, nil)
        }
        if let preview { progress(preview) }
        return try await withTaskCancellationHandler {
            defer { leave(key, load, token, cancelling: false) }
            guard let task = lock.withLock({ load.task }) else { throw CancellationError() }
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            leave(key, load, token, cancelling: true)
        }
    }

    private func broadcast(_ image: DecodedImage, from load: Load) {
        let handlers = lock.withLock { () -> [ImageProgress] in load.preview = image; return Array(load.waiters.values) }
        handlers.forEach { $0(image) }
    }

    private func leave(_ key: String, _ load: Load, _ token: UUID, cancelling: Bool) {
        let task = lock.withLock { () -> Task<ImagePayload, Error>? in
            guard load.waiters.removeValue(forKey: token) != nil, load.waiters.isEmpty, cancelling else { return nil }
            if loads[key] === load { loads.removeValue(forKey: key) }
            return load.task
        }
        task?.cancel()
    }

    private func finish(_ key: String, _ load: Load) {
        lock.withLock { if loads[key] === load { loads.removeValue(forKey: key) } }
    }
}
