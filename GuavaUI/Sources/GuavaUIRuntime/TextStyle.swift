import CoreText
import Foundation

public enum FontWeight: Hashable, Sendable {
    case regular
    case medium
    case semibold
    case bold

    var coreTextWeight: CGFloat {
        switch self {
        case .regular: return 0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        }
    }
}

public struct Font: Hashable, Sendable {
    public let size: Float
    public let weight: FontWeight

    public init(size: Float, weight: FontWeight = .regular) {
        self.size = max(1, size)
        self.weight = weight
    }

    public static func system(size: Float, weight: FontWeight = .regular) -> Font {
        Font(size: size, weight: weight)
    }
}

/// Lazily creates sized/weighted `FontProvider`s that share a single atlas.
/// Each provider gets its own font-ID range so glyph rasterization remains
/// unambiguous even when multiple sizes are used in the same frame.
public final class TextFontResolver: @unchecked Sendable {
    private let primaryFontName: String
    private let atlas: FontAtlas
    private let rasterScale: Float
    private let providerIDBlockSize: Int
    private var nextProviderIDBase: Int
    private var providers: [Font: FontProvider] = [:]
    private let lock = NSLock()

    public init(primaryFontName: String,
                atlas: FontAtlas,
                providerIDBlockSize: Int = 256,
                rasterScale: Float = 1) {
        let blockSize = max(32, providerIDBlockSize)
        self.primaryFontName = primaryFontName
        self.atlas = atlas
        self.rasterScale = max(1, rasterScale)
        self.providerIDBlockSize = blockSize
        self.nextProviderIDBase = max(256, blockSize)
    }

    public func shape(text: String, font: Font) -> [ShapedGlyph] {
        guard !primaryFontName.isEmpty else { return [] }
        lock.lock()
        let provider = provider(for: font)
        let runs = provider.resolveRuns(text: text)
        provider.registerAllFonts(in: atlas)
        let glyphs = runs.flatMap(provider.shapeRun)
        lock.unlock()
        return glyphs
    }

    public func preparePrimaryFont(_ font: Font) -> ManagedFont? {
        guard !primaryFontName.isEmpty else { return nil }
        lock.lock()
        let primary = provider(for: font).primaryFont
        lock.unlock()
        return primary
    }

    private func provider(for font: Font) -> FontProvider {
        if let existing = providers[font] {
            return existing
        }

        let provider = FontProvider(size: font.size,
                        rasterScale: rasterScale,
                        idBase: nextProviderIDBase)
        nextProviderIDBase += providerIDBlockSize
        _ = provider.loadPrimaryFont(name: primaryFontName, weight: font.weight)
        provider.registerAllFonts(in: atlas)
        providers[font] = provider
        return provider
    }
}