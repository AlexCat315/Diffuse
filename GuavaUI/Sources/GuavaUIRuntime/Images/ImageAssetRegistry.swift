import Foundation

/// Thread-safe CPU image cache. Immutable assets travel with geometry; each
/// renderer uploads them on its own recording thread, without a main-thread GPU
/// dependency. Clearing the cache does not invalidate retained nodes or frames.
public final class ImageAssetRegistry: @unchecked Sendable {
    public final class Asset: UITextureAsset, Equatable {
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

    /// Cache budget. Least recently used entries are released once either bound
    /// is exceeded; retained nodes and in-flight frames keep their own assets.
    public struct Limits: Sendable, Equatable {
        public var maximumBytes: Int
        public var maximumCount: Int
        public init(maximumBytes: Int = 256 * 1_024 * 1_024, maximumCount: Int = 2_048) {
            self.maximumBytes = max(0, maximumBytes); self.maximumCount = max(0, maximumCount)
        }
    }

    private struct Entry {
        let asset: Asset
        var lastUse: UInt64
        var bytes: Int { asset.image.pixels.count }
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var clock: UInt64 = 0
    private var totalBytes = 0
    private var budget: Limits
    public init(limits: Limits = Limits()) { budget = limits }
    public var revision: UInt64 { lock.withLock { generation } }
    public var limits: Limits {
        get { lock.withLock { budget } }
        set { lock.withLock { budget = newValue; evictIfNeeded() } }
    }
    /// Bytes of CPU pixels currently owned by the cache.
    public var cachedBytes: Int { lock.withLock { totalBytes } }
    public var cachedCount: Int { lock.withLock { cache.count } }

    // MARK: - Lookup

    /// Returns a cached asset for `key`, or `nil` if it hasn't been
    /// registered yet. Cheap; safe to call every frame.
    public func cached(_ key: String) -> Asset? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = cache[key] else { return nil }
        clock &+= 1; entry.lastUse = clock; cache[key] = entry
        return entry.asset
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
            clock &+= 1
            if var hit = cache[key] { hit.lastUse = clock; cache[key] = hit; return hit.asset }
            let asset = try Asset(image: decoded)
            cache[key] = Entry(asset: asset, lastUse: clock)
            totalBytes += asset.image.pixels.count
            evictIfNeeded(keeping: key)
            return asset
        }
    }

    // MARK: - Maintenance

    /// Release cache ownership. Geometry and snapshots retain their own assets;
    /// GPU residency is reclaimed when those references expire.
    public func clear() {
        lock.withLock { cache.removeAll(); totalBytes = 0; generation &+= 1 }
    }

    /// Called under the lock. The newest entry survives even when it alone
    /// exceeds the budget, so a request never evicts its own result.
    private func evictIfNeeded(keeping key: String? = nil) {
        guard totalBytes > budget.maximumBytes || cache.count > budget.maximumCount else { return }
        let order = cache.filter { $0.key != key }.sorted { $0.value.lastUse < $1.value.lastUse }
        for (candidate, entry) in order {
            guard totalBytes > budget.maximumBytes || cache.count > budget.maximumCount else { break }
            cache.removeValue(forKey: candidate)
            totalBytes -= entry.bytes
        }
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
