import Foundation

/// Thread-safe CPU image cache. Immutable assets travel with geometry; each
/// renderer uploads them on its own recording thread, without a main-thread GPU
/// dependency. Clearing the cache does not invalidate retained nodes or frames.
public final class ImageAssetRegistry: @unchecked Sendable {
    public final class Asset: Sendable, Equatable {
        public let textureID: TextureID
        public let image: DecodedImage

        public init(image: DecodedImage) throws {
            guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384 else {
                throw ImageDecodeError.decodeFailure("invalid image asset dimensions")
            }
            let pixels = UInt64(image.width) * UInt64(image.height)
            guard pixels <= 64 * 1_024 * 1_024, UInt64(image.pixels.count) == pixels * 4 else {
                throw ImageDecodeError.decodeFailure("invalid or oversized RGBA image asset payload")
            }
            self.image = image
            textureID = try ImageAssetIDs.shared.allocate()
        }
        public static func == (lhs: Asset, rhs: Asset) -> Bool { lhs === rhs }
    }

    private let lock = NSLock()
    private var cache: [String: Asset] = [:]
    private var generation: UInt64 = 0
    public init() {}
    public var revision: UInt64 { lock.withLock { generation } }

    // MARK: - Lookup

    /// Returns a cached asset for `key`, or `nil` if it hasn't been
    /// registered yet. Cheap; safe to call every frame.
    public func cached(_ key: String) -> Asset? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    // MARK: - Register from disk

    /// Decode the file at `path` (resolved against the working directory)
    /// at an optional `size` and retain it under a freshly-allocated
    /// `TextureID`. Subsequent calls with the same `(path, size)` return
    /// the cached id.
    @discardableResult
    public func texture(file path: String,
                        size: (width: Int, height: Int)? = nil) throws -> Asset {
        let url = URL(fileURLWithPath: path)
        return try texture(url: url, size: size)
    }

    /// URL form of `texture(file:size:)`.
    @discardableResult
    public func texture(url: URL,
                        size: (width: Int, height: Int)? = nil) throws -> Asset {
        let key = Self.key(for: url, size: size)
        if let hit = cached(key) { return hit }
        let decoded = try ImageDecoder.decode(url: url, targetSize: size)
        return try register(key: key, decoded: decoded)
    }

    /// Register an already-decoded bitmap directly. Useful for tests, for
    /// embedded resources loaded via `Bundle`, or when callers want to
    /// keep their own decoder.
    @discardableResult
    public func register(key: String, decoded: DecodedImage) throws -> Asset {
        try lock.withLock {
            if let hit = cache[key] { return hit }
            let asset = try Asset(image: decoded)
            cache[key] = asset
            return asset
        }
    }

    // MARK: - Maintenance

    /// Release cache ownership. Geometry and snapshots retain their own assets;
    /// GPU residency is reclaimed when those references expire.
    public func clear() {
        lock.withLock { cache.removeAll(); generation &+= 1 }
    }

    // MARK: - Key composition

    /// Stable cache key for `(url, size)`. Vector formats round-trip the
    /// requested rasterisation size so multiple sizes coexist; bitmap
    /// formats fold the natural-size key onto the same slot.
    public static func key(for url: URL, size: (Int, Int)?) -> String {
        let path = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        if let s = size {
            return "\(path)#\(s.0)x\(s.1)"
        }
        return path
    }
}

/// Main-thread context slot exposing the active `ImageAssetRegistry` to compose-side
/// helpers (`Image(file:)`, `Button(icon: .file(...))`, etc.). Hosts set this
/// once at startup, mirroring how `InteractionRegistryHolder` and
/// `TextEnvironmentHolder` are wired.
public enum ImageAssetRegistryHolder {
    nonisolated(unsafe) public static var current: ImageAssetRegistry?
}

/// Process-wide content scale used by vector-image rasterizers (SVG/PDF).
/// Hosts publish the active drawable scale so SVG icons can be rasterized
/// at physical-pixel resolution and stay crisp on HiDPI displays.
public enum ContentScaleHolder {
    nonisolated(unsafe) public static var current: Float = 1
}

/// Reserve one process-wide namespace, distinct from caller/font IDs and
/// viewport leases. Assets from independent registries can coexist in a frame.
private final class ImageAssetIDs: @unchecked Sendable {
    static let shared = ImageAssetIDs()
    private let lock = NSLock()
    private var next: TextureID = 0x1000_0000
    func allocate() throws -> TextureID {
        try lock.withLock {
            guard next < 0x4000_0000 else { throw ImageDecodeError.decodeFailure("image texture IDs exhausted") }
            defer { next += 1 }
            return next
        }
    }
}
