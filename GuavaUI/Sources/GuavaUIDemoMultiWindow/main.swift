import Foundation
import GuavaUICompose
import GuavaUIRuntime
import PlatformShell
import RHIWGPU

struct CounterWindowView: View {
    let title: String
    let subtitle: String
    let appearance: Appearance

    @State var clickCount: Int = 0
    @State var notes: String = ""

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            header
            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 16) {
                    card("Event Routing") {
                        Column(alignment: .leading, spacing: 10) {
                            Text("Each window owns an independent view graph and input dispatcher.")
                                .font(.body)
                                .foregroundColor(.onSurfaceVariant)
                            Row(alignment: .center, spacing: 12) {
                                Button("Increment") { clickCount += 1 }
                                Button("Reset") {
                                    clickCount = 0
                                    notes = ""
                                }
                                .buttonStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            Text("Click count: \(clickCount)")
                                .font(.headline)
                                .foregroundColor(.onSurface)
                        }
                    }

                    card("Focus") {
                        Column(alignment: .leading, spacing: 10) {
                            TextField("Type here to move focus into this window", text: $notes, onSubmit: {})
                            Text(notes.isEmpty ? "Focus target: idle" : "Focus target: \(notes)")
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                    }

                    card("Cursor") {
                        Column(alignment: .leading, spacing: 10) {
                            Text("Hover the buttons and text field. Cursor requests stay bound to the active native window.")
                                .font(.body)
                                .foregroundColor(.onSurfaceVariant)
                            Row(alignment: .center, spacing: 10) {
                                Button("Primary") {}
                                Button("Ghost") {}
                                    .buttonStyle(.ghost)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .flex()
        }
        .flex()
        .background(.background)
        .appearance(appearance)
    }

    private var header: some View {
        Row(alignment: .center, spacing: 12) {
            Column(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title)
                    .foregroundColor(.onSurface)
                Text(subtitle)
                    .font(.body)
                    .foregroundColor(.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            Text("Multi-window")
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 20, vertical: 16)
        .background(.surface)
    }

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 12) {
            Text(title.uppercased())
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
            content()
        }
        .padding(16)
        .background(.surface)
        .cornerRadius(12)
    }
}

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
    func uploadAtlasIfNeeded(scale requestedScale: Float,
                             force: Bool) throws -> Bool {
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
        if let existing = textEntries[key] {
            return existing
        }

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

@MainActor
final class DemoWindowRenderer {
    private let title: String
    private let subtitle: String
    private let appearance: Appearance
    private let session: PlatformWindowSession
    private let backend: WGPUBackend
    private let sharedUI: SharedUIResources
    private let drawList = DrawList()
    private let nodeRenderer = NodeRenderer()
    private let graph: ViewGraph

    private var surface: GPUSurface?
    private var didInstallRoot = false
    private var didPresentBootClear = false
    private var isConfigured = false
    private var renderedFrameCount = 0

    init(title: String,
         subtitle: String,
         appearance: Appearance,
         session: PlatformWindowSession,
         backend: WGPUBackend,
         sharedUI: SharedUIResources) {
        self.title = title
        self.subtitle = subtitle
        self.appearance = appearance
        self.session = session
        self.backend = backend
        self.sharedUI = sharedUI
        self.graph = ViewGraph(tree: session.tree, recomposer: session.recomposer)
    }

    func installCallbacks() {
        session.onInit = { [weak self] native, width, height in
            self?.handleInit(native: native, width: width, height: height)
        }
        session.onResize = { [weak self] width, height in
            self?.handleResize(width: width, height: height)
        }
        session.onFrame = { [weak self] _ in
            self?.handleFrame() ?? false
        }
    }

    func prepareFirstFrame() {
        guard !didInstallRoot else { return }
        session.withCurrent {
            sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
            graph.install(root: CounterWindowView(
                title: title,
                subtitle: subtitle,
                appearance: appearance
            ))
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

    private func handleInit(native: NativeRenderSurface,
                            width: UInt32,
                            height: UInt32) {
        do {
            var timing = TimingTrace(label: "[timing] demo.boot.multi[\(title)]")
            surface = try makeSurface(backend: backend, native: native)
            try surface?.configure(
                device: backend.rawDevice!,
                format: .bgra8Unorm,
                width: width,
                height: height,
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
            print("[multi-window demo] init failed for \(title): \(error)")
        }
    }

    private func handleResize(width: UInt32,
                              height: UInt32) {
        guard let surface, let device = backend.rawDevice else { return }
        do {
            try surface.configure(
                device: device,
                format: .bgra8Unorm,
                width: width,
                height: height,
                presentMode: .fifo
            )
            if didInstallRoot {
                sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
                try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: true)
            }
        } catch {
            print("[multi-window demo] resize failed for \(title): \(error)")
        }
    }

    private func handleFrame() -> Bool {
        guard isConfigured,
              let surface else {
            return false
        }

        do {
            var timing = TimingTrace(label: "[timing] demo.frame.multi[\(title)]")
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
                loadOp: .clear,
                storeOp: .store,
                clearColor: clearColor(for: appearance)
            )
            try sharedUI.renderer.render(
                list: drawList,
                pass: pass,
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
            print("[multi-window demo] frame failed for \(title): \(error)")
            return false
        }
    }

}

func clearColor(for appearance: Appearance) -> GPUColor {
    switch appearance {
    case .dark:
        return GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1)
    case .light:
        return GPUColor(r: 0.94, g: 0.95, b: 0.97, a: 1)
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

let backend = WGPUBackend()
try backend.initialize()
let sharedUI = SharedUIResources(backend: backend)

let host = SDL3PlatformHost(title: "GuavaUI Multi-Window Demo")
ClipboardHolder.read = { SDL3Clipboard.read() }
ClipboardHolder.write = { SDL3Clipboard.write($0) }

let workspaceSession = try host.openWindow(
    title: "GuavaUI Multi-Window - Workspace",
    tree: NodeTree(),
    options: WindowOptions(width: 920, height: 620)
)
let inspectorSession = try host.openWindow(
    title: "GuavaUI Multi-Window - Inspector",
    tree: NodeTree(),
    options: WindowOptions(width: 560, height: 460)
)

let windows = [
    DemoWindowRenderer(
        title: "Workspace Window",
        subtitle: "Independent button clicks and text focus stay in this window.",
        appearance: .dark,
        session: workspaceSession,
        backend: backend,
        sharedUI: sharedUI
    ),
    DemoWindowRenderer(
        title: "Inspector Window",
        subtitle: "A second native window exercises cursor and focus routing.",
        appearance: .light,
        session: inspectorSession,
        backend: backend,
        sharedUI: sharedUI
    ),
]

for window in windows {
    window.installCallbacks()
}

host.requestDisplay(windowID: workspaceSession.id)
host.requestDisplay(windowID: inspectorSession.id)

host.run()
try? backend.shutdown()