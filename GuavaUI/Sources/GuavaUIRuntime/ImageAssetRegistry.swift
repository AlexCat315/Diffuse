import Foundation

/// Lazy file → `TextureID` cache. Wraps a `DrawListRenderer`: the first
/// time a key is requested, the registry decodes the image, calls
/// `registerColorTexture(...)` on the renderer with a freshly-allocated
/// `TextureID`, and remembers the result. Repeat lookups return the
/// cached id without touching the disk or the GPU.
///
/// Keys are arbitrary strings — typically a file path plus a size suffix
/// when callers want multiple rasterisations of the same SVG. The default
/// helpers (`texture(file:size:)` / `texture(url:size:)`) build a stable
/// key for you.
///
/// Thread safety: all mutations are guarded by an internal lock so
/// background loaders can prime the cache while the main thread renders.
public final class ImageAssetRegistry: @unchecked Sendable {

    /// Per-asset metadata returned to callers.
    public struct Asset: Sendable, Equatable {
        public let textureID: TextureID
        public let width: Int
        public let height: Int
    }

    /// Renderer this registry uploads textures to. Stored unowned so the
    /// caller controls lifetime — the registry must not outlive its
    /// renderer.
    public let renderer: DrawListRenderer

    /// First TextureID handed out. The font atlas typically uses 1 and the
    /// preview texture uses 2, so we start well above those to avoid
    /// collisions with caller-allocated ids.
    public init(renderer: DrawListRenderer, firstID: TextureID = 100) {
        self.renderer = renderer
        self.nextID = firstID
    }

    private let lock = NSLock()
    private var nextID: TextureID
    private var cache: [String: Asset] = [:]

    // MARK: - Lookup

    /// Returns a cached asset for `key`, or `nil` if it hasn't been
    /// registered yet. Cheap; safe to call every frame.
    public func cached(_ key: String) -> Asset? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    // MARK: - Register from disk

    /// Decode the file at `path` (resolved against the working directory)
    /// at an optional `size` and upload it under a freshly-allocated
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
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        let id = nextID
        nextID &+= 1
        lock.unlock()

        try decoded.pixels.withUnsafeBufferPointer { buf in
            try renderer.registerColorTexture(
                id: id,
                pixels: buf.baseAddress!,
                width: UInt32(decoded.width),
                height: UInt32(decoded.height)
            )
        }
        let asset = Asset(textureID: id, width: decoded.width, height: decoded.height)
        lock.lock()
        cache[key] = asset
        lock.unlock()
        return asset
    }

    // MARK: - Maintenance

    /// Clear the cache. Does **not** unregister textures from the renderer
    /// (the renderer has no public unregister API yet); callers should
    /// recreate the renderer if they need to reclaim GPU memory.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    // MARK: - Key composition

    /// Stable cache key for `(url, size)`. Vector formats round-trip the
    /// requested rasterisation size so multiple sizes coexist; bitmap
    /// formats fold the natural-size key onto the same slot.
    public static func key(for url: URL, size: (Int, Int)?) -> String {
        let path = url.standardizedFileURL.path
        if let s = size {
            return "\(path)#\(s.0)x\(s.1)"
        }
        return path
    }
}

/// TaskLocal slot exposing the active `ImageAssetRegistry` to compose-side
/// helpers (`Image(file:)`, `IconButton(file:)`, etc.). Hosts set this
/// once at startup, mirroring how `InteractionRegistryHolder` and
/// `TextEnvironmentHolder` are wired.
public enum ImageAssetRegistryHolder {
    nonisolated(unsafe) public static var current: ImageAssetRegistry?
}
