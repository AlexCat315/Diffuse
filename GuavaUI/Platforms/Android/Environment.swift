import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// Per-scene font/image services and a queue drained only on Android's UI thread.
final class SceneEnvironment {
    let images = ImageAssetRegistry()
    let surface = State<UIEnvironment>(wrappedValue: UIEnvironment())
    private(set) var text: TextEnvironment?
    private let lock = NSLock()
    private var work: [() -> Void] = []

    var hasWork: Bool { lock.withLock { !work.isEmpty } }

    func configure(scale: Float) {
        guard text == nil else { return }
        text = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName,
            defaultFont: .system(size: 16), defaultLineHeight: 22, rasterScale: scale, atlasEdge: 2048)
    }

    func withCurrent<R>(scale: Float, _ body: () throws -> R) rethrows -> R {
        let previousText = TextEnvironmentHolder.current
        let previousImages = ImageAssetRegistryHolder.current
        let previousQueue = UIWorkSchedulerHolder.enqueue
        let previousScale = ContentScaleHolder.current
        TextEnvironmentHolder.current = text
        ImageAssetRegistryHolder.current = images
        ContentScaleHolder.current = scale
        UIWorkSchedulerHolder.enqueue = { [weak self] work in self?.lock.withLock { self?.work.append(work) } }
        defer {
            TextEnvironmentHolder.current = previousText
            ImageAssetRegistryHolder.current = previousImages
            UIWorkSchedulerHolder.enqueue = previousQueue
            ContentScaleHolder.current = previousScale
        }
        return try body()
    }

    func drain() {
        let pending = lock.withLock { let pending = work; work.removeAll(); return pending }
        pending.forEach { $0() }
    }
}
