import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Typography and vector raster consistency", .serialized)
struct TypographyRasterTests: GuavaUIComposeSerializedSuite {
    @Test("Semantic typography measures the active theme, including line height and tracking")
    func semanticMeasurement() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        let environment = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        TextEnvironmentHolder.current = environment
        defer { TextEnvironmentHolder.current = previous }
        var theme = Theme.defaultDark
        theme.typography.body = TextStyleToken(font: .system(size: 22), lineHeight: 40, letterSpacing: 2)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Text("AB").font(.body).theme(theme))
        graph.computeLayout(width: 400, height: 200)
        func find(_ node: Node) -> Node? { node.layoutNode?.textInputs != nil ? node : node.children.compactMap(find).first }
        let node = find(graph.tree.root!)!
        let measured = node.layoutNode!.textMeasure!
        #expect(measured.key.font == theme.typography.body.font)
        #expect(measured.key.lineHeight == 40 && measured.key.letterSpacing == 2)
        #expect(node.frame.height == 40)
        let expected = environment.cachedLayout(text: "AB", font: theme.typography.body.font, lineHeight: 40, letterSpacing: 2)
        #expect(measured.result.totalWidth == expected.totalWidth)
    } }

    @Test("Editable text uses the same tracking in its render cache and caret measurement")
    func inputTracking() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        let environment = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        TextEnvironmentHolder.current = environment
        defer { TextEnvironmentHolder.current = previous }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: TextField(text: .constant("AB")).letterSpacing(2).frame(width: 240))
        graph.computeLayout(width: 400, height: 200)
        func find(_ node: Node) -> Node? { node.attachments[TextField.surfaceMarkerKey] as? Bool == true ? node : node.children.compactMap(find).first }
        let node = find(graph.tree.root!)!
        node.draw?(DrawList(), .zero)
        let cached = node.attachments["__textfield_render_cache"] as! TextField.LayoutEngine.RenderCacheEntry
        #expect(cached.key.letterSpacing == 2)
        let expected = environment.cachedLayout(text: "AB", font: cached.key.font, lineHeight: cached.key.lineHeight, letterSpacing: 2)
        #expect(cached.layout.totalWidth == expected.totalWidth)
    } }

    @Test("An existing SVG raster follows scale changes without changing logical dimensions")
    func vectorDensityChange() throws { try GlobalTestLock.locked {
        let previousScale = ContentScaleHolder.current, previousRegistry = ImageAssetRegistryHolder.current
        let previousDiagnostic = ImageLoadDiagnostics.onEvent
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("guava-vector-density-\(UUID()).svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\"><path d=\"M2 2L10 10\" stroke=\"white\"/></svg>".write(to: url, atomically: true, encoding: .utf8)
        defer {
            ContentScaleHolder.current = previousScale; ImageAssetRegistryHolder.current = previousRegistry
            ImageLoadDiagnostics.onEvent = previousDiagnostic; try? FileManager.default.removeItem(at: url)
        }
        ImageAssetRegistryHolder.current = nil; ContentScaleHolder.current = 1
        var diagnostics = 0
        ImageLoadDiagnostics.onEvent = { _ in diagnostics += 1 }
        let initial = Image.resolve(path: url.path, width: 14, height: 14)
        let raster = VectorImageRaster(url: url, initial: initial, width: 14, height: 14)
        #expect(initial.sourcePixelSize?.width == 14)
        ContentScaleHolder.current = 2
        #expect(raster.resolve(width: 14, height: 14).sourcePixelSize?.width == 28)
        #expect(raster.resolve(width: 14, height: 14).sourcePixelSize?.width == 28 && diagnostics == 2)
        #expect(raster.resolve(width: 20, height: 20).sourcePixelSize?.width == 40)
        ContentScaleHolder.current = .nan
        #expect(raster.resolve(width: 20, height: 20).sourcePixelSize?.width == 20)
    } }
}
