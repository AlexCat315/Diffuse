import GuavaUICompose
import GuavaUIRuntime

/// Captures host-scoped services once and restores them on lifecycle teardown.
@MainActor
struct ApplicationServices {
    private let text = TextEnvironmentHolder.current
    private let scale = ContentScaleHolder.current
    private let interactions = InteractionRegistryHolder.current
    private let focus = FocusChainHolder.current
    private let capture = PointerCaptureHolder.current
    private let clipboardRead = ClipboardHolder.read
    private let clipboardWrite = ClipboardHolder.write
    private let viewport = ViewportTextureBridgeHolder.current
    private let images = ImageAssetRegistryHolder.current
    private let drops = AssetDropRegistryHolder.current
    private let work = UIWorkSchedulerHolder.enqueue
    private let display = AppDisplayHandleHolder.current
    func restore() {
        TextEnvironmentHolder.current = text
        ContentScaleHolder.current = scale
        InteractionRegistryHolder.current = interactions
        FocusChainHolder.current = focus
        PointerCaptureHolder.current = capture
        ClipboardHolder.read = clipboardRead
        ClipboardHolder.write = clipboardWrite
        ViewportTextureBridgeHolder.current = viewport
        ImageAssetRegistryHolder.current = images
        AssetDropRegistryHolder.current = drops
        UIWorkSchedulerHolder.enqueue = work
        AppDisplayHandleHolder.current = display
    }
}
