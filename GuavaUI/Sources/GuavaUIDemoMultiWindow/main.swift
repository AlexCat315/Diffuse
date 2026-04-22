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

    func uploadAtlasIfNeeded(scale requestedScale: Float,
                             force: Bool) throws {
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
        if let existing = textEntries[key] {
            return existing
        }

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
    private var isConfigured = false

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
            self?.handleFrame()
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

    private func handleInit(native: NativeRenderSurface,
                            width: UInt32,
                            height: UInt32) {
        do {
            prepareFirstFrame()
            surface = try makeSurface(backend: backend, native: native)
            try surface?.configure(
                device: backend.rawDevice!,
                format: .bgra8Unorm,
                width: width,
                height: height,
                presentMode: .fifo
            )
            try sharedUI.configureRenderer(format: .bgra8Unorm)
            try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: true)
            isConfigured = true
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
            sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
            try sharedUI.uploadAtlasIfNeeded(scale: session.contentScaleFactor, force: true)
        } catch {
            print("[multi-window demo] resize failed for \(title): \(error)")
        }
    }

    private func handleFrame() {
        guard isConfigured,
              let surface,
              let root = session.tree.root else {
            return
        }

        do {
            try session.withCurrent {
                sharedUI.publishTextEnvironment(scale: session.contentScaleFactor)
                graph.computeLayoutIfNeeded(
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
        } catch {
            print("[multi-window demo] frame failed for \(title): \(error)")
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
    window.prepareFirstFrame()
    window.installCallbacks()
}

host.run()
try? backend.shutdown()