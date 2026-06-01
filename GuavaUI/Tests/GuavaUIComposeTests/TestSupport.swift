import Foundation
import GuavaUIRuntime
import GuavaUIBundledFonts
@testable import GuavaUICompose

/// All compose tests that mutate the process-wide holders
/// (`InteractionRegistryHolder`, `FocusChainHolder`, `TextEnvironmentHolder`)
/// must run under this lock. Swift Testing parallelises across suites, and
/// `.serialized` only orders cases inside a single suite.
enum GlobalTestLock {
    nonisolated(unsafe) static let lock = NSLock()

    static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

protocol GuavaUIComposeSerializedSuite {}

enum TestTextEnvironmentFactory {
    static let fontPath = BundledFonts.bundledFontURL?.path ?? ""

    static func make(size: Float = 16,
                     lineHeight: Float = 20) -> TextEnvironment {
        let atlas = FontAtlas(width: 512, height: 512)
        atlas.loadFont(path: fontPath, size: size)

        let shaper = TextShaper()
        if let face = atlas.freetypeFace {
            shaper.setFont(ftFace: face, size: size)
        }

        let resolver = TextFontResolver(primaryFontName: "Arial", atlas: atlas)
        return TextEnvironment(
            atlas: atlas,
            shaper: shaper,
            atlasTextureID: 1,
            defaultLineHeight: lineHeight,
            defaultColor: .white,
            defaultFont: .system(size: size),
            fontResolver: resolver
        )
    }
}
