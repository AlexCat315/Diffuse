#if GUAVA_ANDROID_SHOWCASE
import Foundation
import GuavaAndroidContract
import GuavaUICompose
import GuavaUIRuntime
import CounterExample
import GalleryContent

/// Validation content is compiled only into the showcase APK.
final class ShowcaseContent {
    let counter = CounterView()
    let gallery: GalleryView
    let typography: CounterTypography?
    private let mode: SceneLaunch.Mode

    init(launch: SceneLaunch, checkpoint: String) throws {
        mode = launch.mode
        gallery = GalleryView(initialPage: GalleryCatalog.page(named: launch.component) ?? .introduction)
        typography = try mode == .counter ? CounterTypography() : nil
        if let data = checkpoint.data(using: .utf8), !checkpoint.isEmpty {
            let values = try JSONDecoder().decode([String: String].self, from: data)
            if mode == .counter {
                guard counter.restore(values) else { throw CocoaError(.coderReadCorrupt) }
            } else if let page = values["page"].flatMap(GalleryCatalog.page(named:)) { gallery.selectPage(page) }
        }
    }

    func root(scale: Float) -> AnyView {
        guard mode == .counter, let typography else { return AnyView(gallery) }
        return AnyView(counter.compositionLocal(CounterText.painter, { text, list, origin in
            typography.paint(text, into: list, origin: origin, scale: scale)
        }))
    }
    var checkpoint: [String: String] { mode == .counter ? counter.checkpoint : ["page": gallery.currentPage.rawValue] }
    var page: String? { mode == .gallery ? gallery.currentPage.rawValue : nil }
}
#endif
