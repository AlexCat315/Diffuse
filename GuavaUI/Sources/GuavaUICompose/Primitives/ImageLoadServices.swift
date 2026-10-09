import Foundation
import GuavaUIRuntime

/// Boundary between node lifecycle, background decode and UI-thread publication.
final class ImageLoadServices: @unchecked Sendable {
    let id: AnyHashable
    let cached: (String) -> ImageAssetRegistry.Asset?
    let decode: @Sendable (AsyncImageRequest) async throws -> DecodedImage
    let register: (String, DecodedImage) throws -> ImageAssetRegistry.Asset
    let enqueue: (@escaping () -> Void) -> Void
    init(id: AnyHashable, cached: @escaping (String) -> ImageAssetRegistry.Asset?,
         decode: @escaping @Sendable (AsyncImageRequest) async throws -> DecodedImage,
         register: @escaping (String, DecodedImage) throws -> ImageAssetRegistry.Asset,
         enqueue: @escaping (@escaping () -> Void) -> Void) {
        self.id = id; self.cached = cached; self.decode = decode; self.register = register; self.enqueue = enqueue
    }
    static var current: ImageLoadServices? {
        guard let registry = ImageAssetRegistryHolder.current, let enqueue = UIWorkSchedulerHolder.enqueue else { return nil }
        return ImageLoadServices(id: ObjectIdentifier(registry), cached: registry.cached, decode: { request in
            guard let url = request.url else { throw AsyncImageError.unsupportedURL }
            let data = try await ImageDataDownload.load(url: url, policy: request.policy)
            try Task.checkCancellation()
            return try ImageDecoder.decodeThumbnail(data: data, formatHint: url.pathExtension.lowercased(),
                boundingSize: (request.pixelWidth, request.pixelHeight), maximumSourcePixels: request.policy.maximumSourcePixels)
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
