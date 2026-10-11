import GuavaUIRuntime
import NativeRHI
import RenderBackend

/// UI-thread bridge from owned scene images to renderer bindings. Every image
/// lease gets its own slot so old and new snapshots can be drawn together.
/// Native scene and UI frames sharing a Device must be serialized by the host.
public final class ViewportTextureRegistry: ViewportTextureBridge, @unchecked Sendable {
    private final class Registration {
        weak var image: ViewportImage?
        let id: TextureID
        init(image: ViewportImage, id: TextureID) { self.image = image; self.id = id }
    }
    private let renderer: NativeDrawListRenderer
    private var registrations: [ObjectIdentifier: Registration] = [:]
    // Application images start at 100; the top bit belongs to color glyphs.
    private var nextID: TextureID = 0x4000_0000

    public init(renderer: NativeDrawListRenderer) { self.renderer = renderer }
    deinit { for entry in registrations.values { renderer.unregisterTexture(id: entry.id) } }

    public func textureID(for surface: ViewportSurfaceState) -> TextureID? {
        prune()
        guard surface.isValid, let image = surface.image else { return nil }
        let key = ObjectIdentifier(image)
        if let entry = registrations[key] { return entry.id }
        guard nextID < 0x8000_0000 else { return nil }
        do {
            try renderer.registerExternalColorTexture(id: nextID, resource: image.resource)
        } catch { return nil }
        let id = nextID
        nextID += 1
        registrations[key] = Registration(image: image, id: id)
        return id
    }

    /// Cached geometry retains image leases. Bindings can be released once
    /// both the producer's surface and all geometry snapshots let them go.
    public func prune() {
        let expired = registrations.filter { $0.value.image == nil }
        for (key, entry) in expired {
            renderer.unregisterTexture(id: entry.id)
            registrations.removeValue(forKey: key)
        }
    }
}
