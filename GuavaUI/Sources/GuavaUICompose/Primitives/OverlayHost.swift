/// Compatibility wrapper for the new portal system. New roots should use
/// `LayerRoot { ... } portals: { PortalHost() }` so overlays never
/// participate in normal flex layout.
public struct OverlayHost: View {
    public init() {}

    public var body: some View {
        PortalHost()
    }
}
