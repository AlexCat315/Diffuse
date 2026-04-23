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
                        TextField("Notes for tab \(key)",
                                  text: $note,
                                  axis: .vertical,
                                  onSubmit: {})
                            .frame(height: 96)
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
        let environment: TextEnvironment

        init(textureID: TextureID,
             scale: Float,
             atlas: FontAtlas,
             shaper: TextShaper,
             environment: TextEnvironment) {
            self.textureID = textureID
            self.scale = scale
            self.atlas = atlas
            self.shaper = shaper
            self.environment = environment
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
        TextEnvironmentHolder.current = entry.environment
    }

    @discardableResult
    func uploadAtlasIfNeeded(scale requestedScale: Float, force: Bool) throws -> Bool {
        let entry = resolveTextEntry(scale: requestedScale)
        guard force || entry.atlas.isDirty else { return false }

        let payload: (region: FontAtlas.DirtyRegion, pixels: [UInt8])
        if force, entry.atlas.dirtyUploadPayload() == nil {
            payload = (
                FontAtlas.DirtyRegion(x: 0, y: 0,
                                      width: entry.atlas.atlasWidth,
                                      height: entry.atlas.atlasHeight),
                entry.atlas.atlasData
            )
        } else if let dirty = entry.atlas.dirtyUploadPayload() {
            payload = dirty
        } else {
            return false
        }

        try payload.pixels.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try renderer.registerAlphaTexture(
                id: entry.textureID,
                pixels: baseAddress,
                width: UInt32(payload.region.width),
                height: UInt32(payload.region.height),
                originX: UInt32(payload.region.x),
                originY: UInt32(payload.region.y),
                textureWidth: UInt32(entry.atlas.atlasWidth),
                textureHeight: UInt32(entry.atlas.atlasHeight)
            )
        }
        entry.atlas.markClean()
        return true
    }

    private func resolveTextEntry(scale requestedScale: Float) -> TextEntry {
        let scale = max(1, requestedScale)
        let key = Int((scale * 100).rounded())
        if let existing = textEntries[key] { return existing }

        let atlasEdge = max(1024, Int((1024 * scale).rounded(.up)))
        let environment = TextEnvironment.bootstrapped(
            atlasTextureID: TextureID(nextTextureID),
            primaryFontName: SystemFontDefaults.primaryFontName,
            defaultFont: Font.system(size: 18),
            defaultLineHeight: 22,
            defaultColor: .white,
            rasterScale: scale,
            atlasEdge: atlasEdge
        )
        let entry = TextEntry(
            textureID: environment.atlasTextureID,
            scale: scale,
            atlas: environment.atlas,
            shaper: environment.shaper,
            environment: environment
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
    private var didPresentBootClear = false
    private var isConfigured = false
    private var renderedFrameCount = 0

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
            self?.handleFrame() ?? false
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

    @discardableResult
    private func presentBootClearFrame() throws -> Bool {
        guard let surface else { return false }
        guard let frame = try surface.getCurrentTextureView() else {
            session.requestDisplay()
            return false
        }
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(
            colorView: frame.view,
            loadOp: .clear,
            storeOp: .store,
            clearColor: clearColor(for: appearance)
        )
        pass.end()
        let buffer = try encoder.finish()
        backend.submit(buffer)
        surface.present()
        didPresentBootClear = true
        return true
    }

    private func handleInit(native: NativeRenderSurface, width: UInt32, height: UInt32) {
        do {
            var timing = TimingTrace(label: "[timing] demo.boot.dock[\(title)]")
            surface = try makeSurface(backend: backend, native: native)
            try surface?.configure(
                device: backend.rawDevice!,
                format: .bgra8Unorm,
                width: width, height: height,
                presentMode: .fifo
            )
            try sharedUI.configureRenderer(format: .bgra8Unorm)
            timing.mark("surface")
            if !didPresentBootClear {
                _ = try presentBootClearFrame()
            }
            timing.mark("clearPresent")
            isConfigured = true
            let firstVisible = didPresentBootClear ? "clearPresent" : "deferred"
            print(timing.summary(extra: ["firstVisible=\(firstVisible)"]))
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
            if didInstallRoot {
                sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
                try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: true)
            }
        } catch {
            print("[dock-multiwin] resize failed for \(title): \(error)")
        }
    }

    private func handleFrame() -> Bool {
        guard isConfigured, let surface else { return false }
        do {
            var timing = TimingTrace(label: "[timing] demo.frame.dock[\(title)]")
            let nextFrameIndex = renderedFrameCount + 1
            var didHydrate = false
            var didLayout = false
            var didAtlasUpload = false
            try session.withCurrent {
                if !didInstallRoot {
                    prepareFirstFrame()
                    didHydrate = true
                    timing.mark("hydrate")
                }
                sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
                timing.mark("textEnvironment")
                didLayout = graph.computeLayoutIfNeeded(
                    width: Float(session.logicalSize.width),
                    height: Float(session.logicalSize.height)
                )
                timing.mark("layout")
                drawList.reset()
                guard let root = session.tree.root else { return }
                nodeRenderer.render(root: root, into: drawList)
                timing.mark("sceneRender")
                didAtlasUpload = try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: false)
                timing.mark("atlasUpload")
            }
            guard let frame = try surface.getCurrentTextureView() else {
                if didHydrate || nextFrameIndex <= 5 || didAtlasUpload {
                    print(timing.summary(extra: [
                        "frameAttempt=\(nextFrameIndex)",
                        "hydrated=\(didHydrate)",
                        "layoutUpdated=\(didLayout)",
                        "atlasUploaded=\(didAtlasUpload)",
                        "retry=surfaceUnavailable",
                    ]))
                }
                return false
            }
            timing.mark("acquireSurface")
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
            renderedFrameCount = nextFrameIndex
            timing.mark("gpuSubmit")
            if didHydrate || renderedFrameCount <= 5 || didAtlasUpload {
                print(timing.summary(extra: [
                    "frame=\(renderedFrameCount)",
                    "hydrated=\(didHydrate)",
                    "layoutUpdated=\(didLayout)",
                    "atlasUploaded=\(didAtlasUpload)",
                ]))
            }
            return true
        } catch {
            print("[dock-multiwin] frame failed for \(title): \(error)")
            return false
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
        mainRenderer.installCallbacks()
        host.requestDisplay(windowID: mainSession.id)

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
            renderer.installCallbacks()
            host.requestDisplay(windowID: session.id)
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
