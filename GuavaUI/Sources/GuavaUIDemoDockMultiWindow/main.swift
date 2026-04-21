import Foundation
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import PlatformShell
import RHIWGPU

// MARK: - Tab content

struct DockTabContentView: View {
    let key: String
    let appearance: Appearance

    @State var counter: Int = 0
    @State var note: String = ""

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 16) {
                    Text("Tab “\(key)”")
                        .font(.title)
                        .foregroundColor(.onSurface)
                    Text("Drag this tab out of the dock to detach it into a floating window. Drop it on another window's tab bar (or any leaf edge) to redock.")
                        .font(.body)
                        .foregroundColor(.onSurfaceVariant)

                    Box(direction: .column, alignItems: .stretch, spacing: 12) {
                        Text("Per-tab state")
                            .font(.label)
                            .foregroundColor(.onSurfaceMuted)
                        Row(alignment: .center, spacing: 12) {
                            Button("Increment") { counter += 1 }
                            Button("Reset") { counter = 0; note = "" }
                                .buttonStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        Text("Click count: \(counter)")
                            .font(.headline)
                            .foregroundColor(.onSurface)
                        TextField("Notes for tab \(key)", text: $note, onSubmit: {})
                    }
                    .padding(16)
                    .background(.surface)
                    .cornerRadius(12)
                }
                .padding(20)
            }
            .flex()
        }
        .flex()
        .background(.background)
        .appearance(appearance)
    }
}

// MARK: - Shared GPU + text resources (same shape as the multi-window demo)

@MainActor
final class SharedUIResources {
    private final class TextEntry {
        let textureID: TextureID
        let scale: Float
        let atlas: FontAtlas
        let shaper: TextShaper
        let fontResolver: TextFontResolver

        init(textureID: TextureID,
             scale: Float,
             atlas: FontAtlas,
             shaper: TextShaper,
             fontResolver: TextFontResolver) {
            self.textureID = textureID
            self.scale = scale
            self.atlas = atlas
            self.shaper = shaper
            self.fontResolver = fontResolver
        }
    }

    private let backend: WGPUBackend
    let renderer: DrawListRenderer

    private var textEntries: [Int: TextEntry] = [:]
    private var nextTextureID: UInt32 = 1

    init(backend: WGPUBackend) {
        self.backend = backend
        self.renderer = DrawListRenderer(backend: backend)
    }

    func configureRenderer(format: GPUTextureFormat) throws {
        try renderer.configure(format: format)
    }

    func publishTextEnvironment(scale requestedScale: Float) {
        let entry = resolveTextEntry(scale: requestedScale)
        TextEnvironmentHolder.current = TextEnvironment(
            atlas: entry.atlas,
            shaper: entry.shaper,
            atlasTextureID: entry.textureID,
            defaultLineHeight: 22,
            defaultColor: .white,
            defaultFont: Font.system(size: 18),
            fontResolver: entry.fontResolver
        )
    }

    func uploadAtlasIfNeeded(scale requestedScale: Float, force: Bool) throws {
        let entry = resolveTextEntry(scale: requestedScale)
        guard force || entry.atlas.isDirty else { return }
        try entry.atlas.atlasData.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try renderer.registerAlphaTexture(
                id: entry.textureID,
                pixels: baseAddress,
                width: UInt32(entry.atlas.atlasWidth),
                height: UInt32(entry.atlas.atlasHeight)
            )
        }
        entry.atlas.markClean()
    }

    private func resolveTextEntry(scale requestedScale: Float) -> TextEntry {
        let scale = max(1, requestedScale)
        let key = Int((scale * 100).rounded())
        if let existing = textEntries[key] { return existing }

        let provider = FontProvider(size: 18, rasterScale: scale)
        provider.loadPrimaryFont(name: "Helvetica Neue")

        let atlasEdge = max(1024, Int((1024 * scale).rounded(.up)))
        let atlas = FontAtlas(width: atlasEdge, height: atlasEdge)
        atlas.loadFont(path: "/System/Library/Fonts/Helvetica.ttc", size: 18, rasterScale: scale)

        let shaper = TextShaper()
        if let face = atlas.freetypeFace {
            shaper.setFont(ftFace: face, size: 18, rasterScale: scale)
        }

        let resolver = TextFontResolver(
            primaryFontName: provider.primaryFont?.postScriptName ?? "Helvetica Neue",
            atlas: atlas,
            rasterScale: scale
        )
        let entry = TextEntry(
            textureID: TextureID(nextTextureID),
            scale: scale,
            atlas: atlas,
            shaper: shaper,
            fontResolver: resolver
        )
        nextTextureID += 1
        textEntries[key] = entry
        return entry
    }
}

// MARK: - Per-window renderer

@MainActor
final class DockWindowRenderer {
    let session: PlatformWindowSession
    private let title: String
    private let appearance: Appearance
    private let backend: WGPUBackend
    private let sharedUI: SharedUIResources
    private let drawList = DrawList()
    private let nodeRenderer = NodeRenderer()
    let graph: ViewGraph
    private let rootViewBuilder: () -> AnyView

    private var surface: GPUSurface?
    private var didInstallRoot = false
    private var isConfigured = false

    init(title: String,
         appearance: Appearance,
         session: PlatformWindowSession,
         backend: WGPUBackend,
         sharedUI: SharedUIResources,
         rootViewBuilder: @escaping () -> AnyView) {
        self.title = title
        self.appearance = appearance
        self.session = session
        self.backend = backend
        self.sharedUI = sharedUI
        self.graph = ViewGraph(tree: session.tree, recomposer: session.recomposer)
        self.rootViewBuilder = rootViewBuilder
    }

    func installCallbacks() {
        session.onInit = { [weak self] native, w, h in
            self?.handleInit(native: native, width: w, height: h)
        }
        session.onResize = { [weak self] w, h in
            self?.handleResize(width: w, height: h)
        }
        session.onFrame = { [weak self] _ in
            self?.handleFrame()
        }
    }

    func prepareFirstFrame() {
        guard !didInstallRoot else { return }
        session.withCurrent {
            sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
            graph.install(root: rootViewBuilder())
            graph.computeLayout(
                width: Float(session.logicalSize.width),
                height: Float(session.logicalSize.height)
            )
        }
        didInstallRoot = true
    }

    private func handleInit(native: NativeRenderSurface, width: UInt32, height: UInt32) {
        do {
            prepareFirstFrame()
            surface = try makeSurface(backend: backend, native: native)
            try surface?.configure(
                device: backend.rawDevice!,
                format: .bgra8Unorm,
                width: width, height: height,
                presentMode: .fifo
            )
            try sharedUI.configureRenderer(format: .bgra8Unorm)
            try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: true)
            isConfigured = true
        } catch {
            print("[dock-multiwin] init failed for \(title): \(error)")
        }
    }

    private func handleResize(width: UInt32, height: UInt32) {
        guard let surface, let device = backend.rawDevice else { return }
        do {
            try surface.configure(
                device: device,
                format: .bgra8Unorm,
                width: width, height: height,
                presentMode: .fifo
            )
            sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
            try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: true)
        } catch {
            print("[dock-multiwin] resize failed for \(title): \(error)")
        }
    }

    private func handleFrame() {
        guard isConfigured, let surface, let root = session.tree.root else { return }
        do {
            try session.withCurrent {
                sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
                graph.computeLayout(
                    width: Float(session.logicalSize.width),
                    height: Float(session.logicalSize.height)
                )
                try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: false)
                drawList.reset()
                nodeRenderer.render(root: root, into: drawList)
            }
            guard let frame = try surface.getCurrentTextureView() else { return }
            let encoder = try backend.createCommandEncoder()
            let pass = try encoder.beginRenderPass(
                colorView: frame.view,
                loadOp: .clear, storeOp: .store,
                clearColor: clearColor(for: appearance)
            )
            try sharedUI.renderer.render(
                list: drawList, pass: pass,
                viewportPx: (session.drawableSize.width, session.drawableSize.height),
                coordinateSpace: (Float(session.logicalSize.width), Float(session.logicalSize.height))
            )
            pass.end()
            let buffer = try encoder.finish()
            backend.submit(buffer)
            surface.present()
        } catch {
            print("[dock-multiwin] frame failed for \(title): \(error)")
        }
    }
}

func clearColor(for appearance: Appearance) -> GPUColor {
    switch appearance {
    case .dark:  return GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1)
    case .light: return GPUColor(r: 0.94, g: 0.95, b: 0.97, a: 1)
    }
}

@MainActor
func makeSurface(backend: WGPUBackend,
                 native: NativeRenderSurface) throws -> GPUSurface {
    switch native {
    case .metalLayer(let ptr):
        return try backend.createSurfaceMetal(layer: ptr)
    case .win32Window(let hwnd, let hinstance):
        return try backend.createSurfaceWin32(hwnd: hwnd, hinstance: hinstance)
    case .waylandSurface(let display, let surface):
        return try backend.createSurfaceWayland(display: display, surface: surface)
    case .xlibWindow(let display, let window):
        return try backend.createSurfaceXlib(display: display, window: window)
    }
}

// MARK: - App boot

@MainActor
final class DockMultiWindowApp {
    let backend: WGPUBackend
    let sharedUI: SharedUIResources
    let host: SDL3PlatformHost
    let controller: DockController
    let coordinator: DockHostCoordinator

    /// Per-leaf renderers for satellite windows. Owns the renderer so the
    /// graph + GPU surface stay alive while the satellite window exists.
    var satelliteRenderers: [DockNodeID: DockWindowRenderer] = [:]

    init() throws {
        self.backend = WGPUBackend()
        try backend.initialize()
        self.sharedUI = SharedUIResources(backend: backend)
        self.host = SDL3PlatformHost(title: "GuavaUI Dock Multi-Window Demo")

        let leafA = DockTab(userKey: "outline",  title: "Outline")
        let leafB = DockTab(userKey: "props",    title: "Properties")
        let leafC = DockTab(userKey: "log",      title: "Log")
        let root: DockLayoutNode = .hsplit(
            fraction: 0.45,
            first: .tabs([leafA, leafB]),
            second: .tabs([leafC])
        )
        self.controller = DockController(root: root)
        self.coordinator = DockHostCoordinator(controller: controller)
    }

    func run() throws {
        ClipboardHolder.read = { SDL3Clipboard.read() }
        ClipboardHolder.write = { SDL3Clipboard.write($0) }

        let mainSession = try host.openWindow(
            title: "GuavaUI Dock - Workspace",
            tree: NodeTree(),
            options: WindowOptions(width: 1100, height: 720)
        )
        let mainBridge = makeBridge(windowID: mainSession.id,
                                    session: mainSession,
                                    satelliteFor: nil)

        let mainRenderer = DockWindowRenderer(
            title: "Workspace",
            appearance: .dark,
            session: mainSession,
            backend: backend,
            sharedUI: sharedUI
        ) { [controller] in
            AnyView(
                DockContainer(controller: controller,
                              hostBridge: mainBridge) { key in
                    AnyView(DockTabContentView(key: key, appearance: .dark))
                }
            )
        }
        mainRenderer.prepareFirstFrame()
        mainRenderer.installCallbacks()

        // Satellite spawn: open a new SDL window, build a graph rooted at
        // `DockSatelliteView(leafID:)`, and remember the renderer.
        coordinator.onSpawnSatellite = { [weak self] leafID, _, originHint in
            guard let self else { return }
            self.spawnSatellite(leafID: leafID, originHint: originHint)
        }
        coordinator.onCloseSatelliteWindow = { [weak self] leafID in
            guard let self else { return }
            self.closeSatellite(leafID: leafID)
        }

        host.run()
    }

    private func spawnSatellite(leafID: DockNodeID,
                                originHint: (x: Float, y: Float)) {
        let title = "Detached"
        do {
            let session = try host.openWindow(
                title: title,
                tree: NodeTree(),
                options: WindowOptions(width: 480, height: 360)
            )
            host.setWindowPosition(session.id,
                                   x: max(originHint.x - 60, 0),
                                   y: max(originHint.y - 24, 0))

            let bridge = makeBridge(windowID: session.id,
                                    session: session,
                                    satelliteFor: leafID)

            let renderer = DockWindowRenderer(
                title: title,
                appearance: .light,
                session: session,
                backend: backend,
                sharedUI: sharedUI
            ) { [controller] in
                AnyView(
                    DockSatelliteView(controller: controller,
                                      leafID: leafID,
                                      hostBridge: bridge) { key in
                        AnyView(DockTabContentView(key: key, appearance: .light))
                    }
                )
            }
            renderer.prepareFirstFrame()
            renderer.installCallbacks()
            satelliteRenderers[leafID] = renderer
        } catch {
            print("[dock-multiwin] failed to spawn satellite for \(leafID): \(error)")
        }
    }

    private func closeSatellite(leafID: DockNodeID) {
        guard let renderer = satelliteRenderers.removeValue(forKey: leafID) else { return }
        // Drop the coordinator entry so cross-window pointer routing
        // doesn't keep resolving onto the dead window.
        if let entry = coordinator.host(for: renderer.session.id) {
            coordinator.unregisterHost(entry.id)
        }
        host.closeWindow(renderer.session.id)
    }

    private func makeBridge(windowID: WindowID,
                            session: PlatformWindowSession,
                            satelliteFor leafID: DockNodeID?) -> DockHostBridge {
        let host = self.host
        return DockHostBridge(
            coordinator: coordinator,
            windowID: windowID,
            satelliteFor: leafID,
            originProvider: { host.windowPosition(windowID) },
            logicalSizeProvider: {
                (Float(session.logicalSize.width),
                 Float(session.logicalSize.height))
            }
        )
    }
}

let app = try DockMultiWindowApp()
try app.run()
