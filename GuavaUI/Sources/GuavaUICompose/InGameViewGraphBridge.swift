import Foundation
import GuavaUIRuntime

/// Main-thread owner of a GuavaUI `ViewGraph` for in-game HUD rendering.
///
/// Call `setRootView(_:)` once to install any GuavaUI `View` tree, then
/// call `tick(width:height:)` every frame (main thread only) to recompose,
/// layout, render, and publish a `DrawListSnapshot` for the render thread.
///
/// The render thread reads the snapshot via `InGameDrawListSource` and
/// composites it on top of the 3-D scene through `InGameUIRenderer`.
///
/// Thread contract:
/// - `setRootView` and `tick` must be called on the main thread.
/// - `InGameDrawListSource.consume()` is safe from any thread.
public final class InGameViewGraphBridge {

    private let tree = NodeTree()
    private let recomposer = Recomposer()
    private let graph: ViewGraph
    private let layerRenderer = LayerAwareNodeRenderer()
    private let drawList = DrawList()
    private let source: InGameDrawListSource
    private let atlasTextureID: TextureID

    private var textEnv: TextEnvironment?
    private var lastScale: Float = 0
    private var didInstallRoot = false

    public init(source: InGameDrawListSource, atlasTextureID: TextureID = 1) {
        self.source = source
        self.atlasTextureID = atlasTextureID
        self.graph = ViewGraph(tree: tree, recomposer: recomposer)
    }

    // MARK: - Main-thread API

    /// Install a GuavaUI `View` tree as the in-game HUD. Call once before the
    /// first `tick`. Subsequent calls are ignored — swap the root via `@State`
    /// on a wrapping view if dynamic root changes are needed.
    public func setRootView<V: View>(_ view: V) {
        guard !didInstallRoot else { return }
        ensureTextEnvironment(scale: 1)
        withTextEnvInstalled { graph.install(root: view) }
        didInstallRoot = true
    }

    /// Advance the in-game UI by one frame. Must be called on the main thread,
    /// typically inside the engine's `onTick` callback, after all game-state
    /// `@Observable` writes for this frame have been applied.
    ///
    /// Recomposes dirty scopes, runs Yoga layout, renders the node tree into a
    /// `DrawList`, snapshots the result, and publishes it to the render thread.
    public func tick(width: Int, height: Int) {
        guard width > 0, height > 0, didInstallRoot else { return }
        ensureTextEnvironment(scale: 1)

        withTextEnvInstalled {
            _ = recomposer.commitAll()
            _ = graph.computeLayoutIfNeeded(width: Float(width), height: Float(height))
            drawList.reset()
            layerRenderer.render(tree: graph.renderTree, into: drawList)
        }

        var atlasDirty: DrawListAtlasDirty? = nil
        if let env = textEnv, env.atlas.isDirty,
           let payload = env.atlas.dirtyUploadPayload() {
            atlasDirty = DrawListAtlasDirty(
                pixels: payload.pixels,
                regionX: UInt32(payload.region.x),
                regionY: UInt32(payload.region.y),
                regionWidth: UInt32(payload.region.width),
                regionHeight: UInt32(payload.region.height),
                textureWidth: UInt32(env.atlas.atlasWidth),
                textureHeight: UInt32(env.atlas.atlasHeight),
                textureID: atlasTextureID
            )
            env.atlas.markClean()
        }

        source.publish(DrawListSnapshot(
            vertices: drawList.vertices,
            indices: drawList.indices,
            batches: drawList.batches,
            viewportWidth: UInt32(width),
            viewportHeight: UInt32(height),
            logicalWidth: Float(width),
            logicalHeight: Float(height),
            atlasDirty: atlasDirty
        ))
    }

    // MARK: - Private

    private func ensureTextEnvironment(scale: Float) {
        let s = max(1, scale)
        guard abs(s - lastScale) > 0.01 else { return }
        lastScale = s
        textEnv = TextEnvironment.bootstrapped(
            atlasTextureID: atlasTextureID,
            primaryFontName: ".AppleSystemUIFont",
            defaultFont: .system(size: 16),
            defaultLineHeight: 20,
            defaultColor: .white,
            rasterScale: s,
            atlasEdge: max(512, Int((512 * s).rounded(.up)))
        )
    }

    /// Run `body` with this bridge's `TextEnvironment` installed as the
    /// process-wide current env, then restore whatever was there before.
    private func withTextEnvInstalled(_ body: () -> Void) {
        let previousEnv = TextEnvironmentHolder.current
        let previousScale = ContentScaleHolder.current
        TextEnvironmentHolder.current = textEnv
        ContentScaleHolder.current = lastScale > 0 ? lastScale : 1
        body()
        TextEnvironmentHolder.current = previousEnv
        ContentScaleHolder.current = previousScale
    }
}
