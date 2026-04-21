import Foundation
import GuavaUIRuntime
import GuavaUICompose
import PlatformShell
import RHIWGPU

struct DemoSceneNode: Identifiable {
    let id: String
    let title: String
    let children: [DemoSceneNode]
}

struct DemoLogEntry: Identifiable {
    let id: Int
    let level: String
    let message: String
}

let demoSceneTree: [DemoSceneNode] = [
    DemoSceneNode(id: "scene", title: "Scene Root", children: [
        DemoSceneNode(id: "camera", title: "Main Camera", children: []),
        DemoSceneNode(id: "lights", title: "Lights", children: [
            DemoSceneNode(id: "sun", title: "Directional Light", children: []),
            DemoSceneNode(id: "fill", title: "Fill Light", children: [])
        ]),
        DemoSceneNode(id: "props", title: "Props", children: [
            DemoSceneNode(id: "crate", title: "Crate_A", children: []),
            DemoSceneNode(id: "monitor", title: "MonitorWall", children: []),
            DemoSceneNode(id: "console", title: "ConsoleDesk", children: [])
        ])
    ])
]

let demoLogEntries: [DemoLogEntry] = [
    DemoLogEntry(id: 1, level: "INFO", message: "Renderer warmed 1024 atlas glyphs."),
    DemoLogEntry(id: 2, level: "INFO", message: "List and Tree compose components are active in the demo."),
    DemoLogEntry(id: 3, level: "WARN", message: "Rounded clip is still axis-aligned at the subtree level."),
    DemoLogEntry(id: 4, level: "INFO", message: "Scene hierarchy selection now feeds inspector text."),
    DemoLogEntry(id: 5, level: "DEBUG", message: "ScrollView wheel routing drives both components."),
    DemoLogEntry(id: 6, level: "INFO", message: "Phase 7 foundation is ready for SplitView and DockContainer."),
]

/// Longer log list — used by the scrollable Console panel to exercise
/// `ScrollView` wheel routing and Text shape caching together.
let scrollableLogEntries: [DemoLogEntry] = (0..<60).map { i in
    let level: String
    switch i % 4 {
    case 0: level = "INFO"
    case 1: level = "DEBUG"
    case 2: level = "WARN"
    default: level = "INFO"
    }
    return DemoLogEntry(
        id: 100 + i,
        level: level,
        message: "log #\(i): frame \(i * 16) ms, alloc \(i * 32) bytes, draw calls \(8 + i % 7)."
    )
}

func demoLogColor(_ level: String) -> SemanticColorRef {
    switch level {
    case "WARN":  return .warning
    case "DEBUG": return .info
    case "ERROR": return .error
    default:      return .success
    }
}

func demoSceneTitle(id: String?) -> String {
    guard let id else { return "None" }
    return findDemoSceneNode(id: id, in: demoSceneTree)?.title ?? id
}

func findDemoSceneNode(id: String,
                       in nodes: [DemoSceneNode]) -> DemoSceneNode? {
    for node in nodes {
        if node.id == id { return node }
        if let match = findDemoSceneNode(id: id, in: node.children) {
            return match
        }
    }
    return nil
}

// MARK: - Root view (compose)

/// Showcase app for the Phase 8.1 design system.
///
/// Layout: classic 3-pane IDE chrome — left navigation (`surfaceVariant`),
/// centre workspace (`background` with `surface` cards), right inspector
/// (`surfaceVariant`). Every colour is read through `SemanticColorRef` or
/// `theme.colors.*`; no raw `Color(red:...)` literals appear in the UI.
struct RootView: View {
    @State var inputText: String = "guava"
    @State var clickCount: Int = 0
    @State var selectedSceneNodeID: String? = "camera"
    @State var selectedLogID: Int? = 102
    @State var appearance: Appearance = .dark
    @State var volume: Double = 0.62
    @State var brightness: Double = 0.40
    @State var quality: Double = 3
    @State var searchText: String = ""
    @State var tagText: String = ""
    @State var section: NavSection = .components

    enum NavSection: String, Hashable, CaseIterable, Identifiable {
        case components, tokens, layouts, console
        var id: String { rawValue }
        var title: String {
            switch self {
            case .components: return "Components"
            case .tokens:     return "Design Tokens"
            case .layouts:    return "Layouts"
            case .console:    return "Console"
            }
        }
        var hint: String {
            switch self {
            case .components: return "Buttons · TextFields · Sliders"
            case .tokens:     return "Surfaces · Accent · State layers"
            case .layouts:    return "Tree · List · Split"
            case .console:    return "Streaming log feed"
            }
        }
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch) {
            topBar
            SplitView(.horizontal, fraction: 0.18) {
                sidebar
            } second: {
                SplitView(.horizontal, fraction: 0.74) {
                    workspace
                } second: {
                    inspector
                }
            }
            .flex()
            statusBar
        }
        .flex()
        .background(.background)
        .appearance(appearance)
        // Cross-fade the entire window when appearance flips.
        .animation(.easeInOut(duration: 0.28), value: appearance)
    }

    // MARK: top bar

    private var topBar: some View {
        Row(alignment: .center, spacing: 12) {
            Text("● ● ●")
                .font(.body)
                .foregroundColor(.onSurfaceMuted)
            Text("GuavaUI Studio")
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            Text("/")
                .font(.body)
                .foregroundColor(.onSurfaceMuted)
            Text(section.title)
                .font(.body)
                .foregroundColor(.onSurfaceVariant)
            Spacer(minLength: 0)
            Button("Run") { clickCount += 1 }
            Button("Inspect") { clickCount += 1 }
                .buttonStyle(.secondary)
            Button(appearance == .dark ? "☀︎ Light" : "☾ Dark") {
                appearance = (appearance == .dark) ? .light : .dark
            }
            .buttonStyle(.ghost)
        }
        .padding(horizontal: 16, vertical: 10)
        .background(.surface)
    }

    // MARK: sidebar

    private var sidebar: some View {
        Box(direction: .column, alignItems: .stretch) {
            Text("WORKSPACE")
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 16, vertical: 12)

            Box(direction: .column, alignItems: .stretch, spacing: 2) {
                sidebarRow(.components)
                sidebarRow(.tokens)
                sidebarRow(.layouts)
                sidebarRow(.console)
            }
            .padding(horizontal: 8, vertical: 0)

            Box(direction: .column, alignItems: .stretch) { EmptyView() }
                .frame(height: 16)
            Divider()

            Text("HIERARCHY")
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 16, vertical: 12)

            Tree(demoSceneTree,
                 children: \.children,
                 selection: $selectedSceneNodeID,
                 rowHeight: 26,
                 rowSpacing: 1) { node, _, _, _ in
                Text(node.title)
                    .font(.body)
                    .foregroundColor(.onSurface)
            }
            .flex()
        }
        .background(.surfaceVariant)
    }

    private func sidebarRow(_ item: NavSection) -> some View {
        let isActive = (section == item)
        // Wrap the row in a Ghost-style Button so taps route through the
        // existing pointer pipeline; no separate gesture modifier required.
        return Button(action: { section = item }) {
            Row(alignment: .center, spacing: 10) {
                Box { EmptyView() }
                    .frame(width: 3, height: 18)
                    .background(isActive ? .accent : .surfaceVariant)
                    .cornerRadius(2)
                Column(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.bodyStrong)
                        .foregroundColor(isActive ? .accent : .onSurface)
                    Text(item.hint)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .flex()
            }
            .padding(horizontal: 10, vertical: 8)
            .background(isActive ? .accentMuted : .surfaceVariant)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: workspace

    @ViewBuilder
    private var workspace: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: 18) {
                workspaceHeader
                switch section {
                case .components: componentsPage
                case .tokens:     tokensPage
                case .layouts:    layoutsPage
                case .console:    consolePage
                }
                Spacer().frame(height: 24)
            }
            .padding(24)
        }
        .flex()
    }

    private var workspaceHeader: some View {
        Column(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.title)
                .foregroundColor(.onBackground)
            Text(section.hint)
                .font(.body)
                .foregroundColor(.onSurfaceVariant)
        }
    }

    // MARK: components page

    private var componentsPage: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 16) {
            card("Buttons") {
                Column(alignment: .leading, spacing: 12) {
                    Row(alignment: .center, spacing: 10) {
                        Button("Primary") { clickCount += 1 }
                        Button("Secondary") { clickCount += 1 }
                            .buttonStyle(.secondary)
                        Button("Ghost") { clickCount += 1 }
                            .buttonStyle(.ghost)
                        Button("Delete", role: .destructive) { clickCount += 1 }
                        Spacer(minLength: 0)
                    }
                    Row(alignment: .center, spacing: 10) {
                        Button("Disabled", isEnabled: false) {}
                        Button("Disabled", isEnabled: false) {}
                            .buttonStyle(.secondary)
                        Button("Disabled", isEnabled: false) {}
                            .buttonStyle(.ghost)
                        Button("Disabled", role: .destructive, isEnabled: false) {}
                        Spacer(minLength: 0)
                    }
                    Text("Click count: \(clickCount)")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }

            card("Text fields") {
                Box(direction: .column, alignItems: .stretch, spacing: 10) {
                    TextField("Search…", text: $searchText, onSubmit: {})
                    Row(alignment: .center, spacing: 10) {
                        TextField("Project name", text: $inputText, onSubmit: {})
                            .flex()
                        TextField("Tag", text: $tagText, onSubmit: {})
                            .frame(width: 140)
                    }
                    Text("echo: \(inputText)")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }

            card("Sliders") {
                Column(alignment: .leading, spacing: 10) {
                    sliderRow("Volume",     value: $volume,     suffix: "\(Int(volume * 100))")
                    sliderRow("Brightness", value: $brightness, suffix: String(format: "%.2f", brightness))
                    Row(alignment: .center, spacing: 12) {
                        Text("Quality")
                            .font(.body)
                            .foregroundColor(.onSurface)
                            .frame(width: 90)
                        Slider(value: $quality, range: 1...5, step: 1).flex()
                        Text("Lv \(Int(quality))")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .frame(width: 50)
                    }
                }
            }
        }
    }

    private func sliderRow(_ label: String,
                           value: Binding<Double>,
                           suffix: String) -> some View {
        Row(alignment: .center, spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundColor(.onSurface)
                .frame(width: 90)
            Slider(value: value, range: 0...1).flex()
            Text(suffix)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 50)
        }
    }

    // MARK: tokens page

    private var tokensPage: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 16) {
            card("Surface ramp") {
                Column(alignment: .leading, spacing: 6) {
                    surfaceSwatch("background",      ref: .background,      onRef: .onBackground)
                    surfaceSwatch("surfaceSunken",   ref: .surfaceSunken,   onRef: .onSurfaceVariant)
                    surfaceSwatch("surface",         ref: .surface,         onRef: .onSurface)
                    surfaceSwatch("surfaceVariant",  ref: .surfaceVariant,  onRef: .onSurface)
                    surfaceSwatch("surfaceRaised",   ref: .surfaceRaised,   onRef: .onSurface)
                    surfaceSwatch("surfaceFloating", ref: .surfaceFloating, onRef: .onSurface)
                    surfaceSwatch("surfaceOverlay",  ref: .surfaceOverlay,  onRef: .onSurface)
                }
            }
            card("Accent ramp") {
                Column(alignment: .leading, spacing: 6) {
                    surfaceSwatch("accentMuted",   ref: .accentMuted,   onRef: .onSurface)
                    surfaceSwatch("accent",        ref: .accent,        onRef: .onAccent)
                    surfaceSwatch("accentHover",   ref: .accentHover,   onRef: .onAccent)
                    surfaceSwatch("accentPressed", ref: .accentPressed, onRef: .onAccent)
                }
            }
            card("Status") {
                Row(alignment: .center, spacing: 8) {
                    statusChip("success", ref: .success)
                    statusChip("info",    ref: .info)
                    statusChip("warning", ref: .warning)
                    statusChip("error",   ref: .error)
                    Spacer(minLength: 0)
                }
            }
            card("Typography") {
                Column(alignment: .leading, spacing: 6) {
                    Text("Display 32 / Bold")     .font(.display)    .foregroundColor(.onSurface)
                    Text("Title 22 / Semibold")   .font(.title)      .foregroundColor(.onSurface)
                    Text("Headline 16 / Semibold").font(.headline)   .foregroundColor(.onSurface)
                    Text("Body 13 / Regular")     .font(.body)       .foregroundColor(.onSurface)
                    Text("BodyStrong 13 / Semi")  .font(.bodyStrong) .foregroundColor(.onSurface)
                    Text("Caption 11 / Regular")  .font(.caption)    .foregroundColor(.onSurfaceVariant)
                    Text("LABEL 10 / Medium")     .font(.label)      .foregroundColor(.onSurfaceMuted)
                }
            }
        }
    }

    private func surfaceSwatch(_ name: String,
                               ref: SemanticColorRef,
                               onRef: SemanticColorRef) -> some View {
        Row(alignment: .center, spacing: 10) {
            Box { EmptyView() }
                .frame(width: 56, height: 28)
                .background(ref)
                .cornerRadius(4)
            Text(name)
                .font(.bodyStrong)
                .foregroundColor(onRef)
                .frame(width: 160)
            Text("token")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Spacer(minLength: 0)
        }
    }

    private func statusChip(_ name: String, ref: SemanticColorRef) -> some View {
        Text(name.uppercased())
            .font(.label)
            .foregroundColor(.onAccent)
            .padding(horizontal: 10, vertical: 4)
            .background(ref)
            .cornerRadius(9999)
    }

    // MARK: layouts page

    private var layoutsPage: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 16) {
            card("Image + chrome") {
                Row(alignment: .top, spacing: 16) {
                    Image(textureID: previewTextureID, width: 112, height: 112)
                        .cornerRadius(16)
                    Column(alignment: .leading, spacing: 6) {
                        Text("Asset preview")
                            .font(.headline)
                            .foregroundColor(.onSurface)
                        Text("Image + cornerRadius + theme tokens, no hard-coded colors. The thumbnail is rasterised at the active content scale every resize.")
                            .font(.body)
                            .foregroundColor(.onSurfaceVariant)
                        Spacer().frame(height: 6)
                        Row(alignment: .center, spacing: 8) {
                            Button("Open") { clickCount += 1 }
                                .buttonStyle(.secondary)
                            Button("Reveal") { clickCount += 1 }
                                .buttonStyle(.ghost)
                        }
                    }
                    .flex()
                }
            }
            card("Selected entity") {
                Column(alignment: .leading, spacing: 4) {
                    Text(demoSceneTitle(id: selectedSceneNodeID))
                        .font(.title)
                        .foregroundColor(.onSurface)
                    Text("type: EntityNode · layout: yoga")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
        }
    }

    // MARK: console page

    private var consolePage: some View {
        card("Stream") {
            ScrollView(.vertical) {
                List(scrollableLogEntries,
                     selection: $selectedLogID,
                     rowHeight: 28,
                     rowSpacing: 1) { entry, _ in
                    Row(alignment: .center, spacing: 10) {
                        Text(entry.level)
                            .font(.bodyStrong)
                            .foregroundColor(demoLogColor(entry.level))
                            .frame(width: 56)
                        Text(entry.message)
                            .font(.body)
                            .foregroundColor(.onSurface)
                    }
                }
                .frame(height: 28 * Float(scrollableLogEntries.count) + 8)
            }
            .frame(height: 360)
        }
    }

    // MARK: card primitive

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
        .cornerRadius(10)
    }

    // MARK: inspector

    private var inspector: some View {
        Box(direction: .column, alignItems: .stretch) {
            Text("INSPECTOR")
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 16, vertical: 12)

            Box(direction: .column, alignItems: .stretch, spacing: 12) {
                inspectorRow("Selection", demoSceneTitle(id: selectedSceneNodeID))
                inspectorRow("Section",   section.title)
                inspectorRow("Theme",     appearance == .dark ? "Default Dark" : "Default Light")
                inspectorRow("Clicks",    "\(clickCount)")
                inspectorRow("Volume",    "\(Int(volume * 100))%")
                Spacer().frame(height: 8)
                Divider()
                Spacer().frame(height: 8)
                Text("Design system")
                    .font(.headline)
                    .foregroundColor(.onSurface)
                Text("5-layer surface ramp · Indigo accent · state-layer overlays. See docs/guava-ui-design-system.md for the slot taxonomy.")
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
                Spacer()
            }
            .padding(horizontal: 16, vertical: 0)
            .flex()
        }
        .background(.surfaceVariant)
    }

    private func inspectorRow(_ key: String, _ value: String) -> some View {
        Row(alignment: .center, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 80)
            Text(value)
                .font(.body)
                .foregroundColor(.onSurface)
                .flex()
        }
    }

    // MARK: status bar

    private var statusBar: some View {
        Row(alignment: .center, spacing: 12) {
            Text("● ready")
                .font(.caption)
                .foregroundColor(.success)
            Text("focus: \(demoSceneTitle(id: selectedSceneNodeID))")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Spacer(minLength: 0)
            Text("GuavaUI · Phase 8.1")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 16, vertical: 6)
        .background(.surfaceVariant)
    }
}

// MARK: - Compose graph

let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Phase 7.5")
let graph = ViewGraph(tree: tree, recomposer: host.recomposer)
InteractionRegistryHolder.current = host.interactions
FocusChainHolder.current = host.focusChain
PointerCaptureHolder.current = host.pointerCapture
ClipboardHolder.read  = { SDL3Clipboard.read() }
ClipboardHolder.write = { SDL3Clipboard.write($0) }

// MARK: - Text environment (font atlas + shaper bound to primary face)

let atlasTextureID: TextureID = 1
let previewTextureID: TextureID = 2

var atlas: FontAtlas?
var shaper: TextShaper?
var fontResolver: TextFontResolver?
var previewTexturePixels: [UInt8] = []
var previewTextureSize: (width: UInt32, height: UInt32) = (0, 0)
var activeTextScale: Float = 0
var didInstallRoot = false
var lastHUDSampleTime = ProcessInfo.processInfo.systemUptime
var hudFrameAccum: Double = 0
var hudFrameCount: Int = 0
var hudFPS: Int = 0
var hudFrameMS: Double = 0

func makePreviewTexturePixels(scale: Float) -> (pixels: [UInt8], width: UInt32, height: UInt32) {
    let logicalWidth: Float = 112
    let logicalHeight: Float = 112
    let physicalWidth = max(1, Int((logicalWidth * scale).rounded(.up)))
    let physicalHeight = max(1, Int((logicalHeight * scale).rounded(.up)))
    let checkerSize = max(1, Int((14 * scale).rounded(.up)))
    var pixels = [UInt8](repeating: 0, count: physicalWidth * physicalHeight * 4)

    for y in 0..<physicalHeight {
        let logicalY = Float(y) / scale
        for x in 0..<physicalWidth {
            let logicalX = Float(x) / scale
            let index = (y * physicalWidth + x) * 4
            let checker = ((x / checkerSize) + (y / checkerSize)).isMultiple(of: 2)
            let r = UInt8(min(255, 36 + Int(logicalX * 2)))
            let g = UInt8(min(255, 74 + Int(logicalY)))
            let b = checker ? UInt8(214) : UInt8(112)

            pixels[index + 0] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
            pixels[index + 3] = 255
        }
    }

    return (pixels, UInt32(physicalWidth), UInt32(physicalHeight))
}

@MainActor
func configureTextEnvironment(scale requestedScale: Float) {
    let scale = max(1, requestedScale)
    guard atlas == nil || abs(scale - activeTextScale) >= 0.01 else { return }

    activeTextScale = scale

    let primaryProvider = FontProvider(size: 18, rasterScale: scale)
    primaryProvider.loadPrimaryFont(name: "Helvetica Neue")

    let atlasEdge = max(1024, Int((1024 * scale).rounded(.up)))
    let newAtlas = FontAtlas(width: atlasEdge, height: atlasEdge)
    newAtlas.loadFont(path: "/System/Library/Fonts/Helvetica.ttc", size: 18, rasterScale: scale)

    let newShaper = TextShaper()
    if let face = newAtlas.freetypeFace {
        newShaper.setFont(ftFace: face, size: 18, rasterScale: scale)
    }

    let newResolver = TextFontResolver(
        primaryFontName: primaryProvider.primaryFont?.postScriptName ?? "Helvetica Neue",
        atlas: newAtlas,
        rasterScale: scale
    )

    let preview = makePreviewTexturePixels(scale: scale)
    previewTexturePixels = preview.pixels
    previewTextureSize = (preview.width, preview.height)
    atlas = newAtlas
    shaper = newShaper
    fontResolver = newResolver

    TextEnvironmentHolder.current = TextEnvironment(
        atlas: newAtlas,
        shaper: newShaper,
        atlasTextureID: atlasTextureID,
        defaultLineHeight: 22,
        defaultColor: Color.white,
        defaultFont: Font.system(size: 18),
        fontResolver: newResolver
    )
}

// MARK: - GPU stack

let backend = WGPUBackend()
try backend.initialize()
let renderer = DrawListRenderer(backend: backend)
let drawList = DrawList()
let nodeRenderer = NodeRenderer()

var surface: GPUSurface?
var configured = false
var drawableW: UInt32 = 0
var drawableH: UInt32 = 0
var logicalW: UInt32 = 0
var logicalH: UInt32 = 0

@MainActor
func uploadAtlas() throws {
    guard let atlas else { return }
    try atlas.atlasData.withUnsafeBufferPointer { buf in
        try renderer.registerAlphaTexture(
            id: atlasTextureID,
            pixels: buf.baseAddress!,
            width: UInt32(atlas.atlasWidth),
            height: UInt32(atlas.atlasHeight)
        )
    }
    atlas.markClean()
}

@MainActor
func uploadPreviewTexture() throws {
    guard !previewTexturePixels.isEmpty else { return }
    try previewTexturePixels.withUnsafeBufferPointer { buf in
        try renderer.registerColorTexture(
            id: previewTextureID,
            pixels: buf.baseAddress!,
            width: previewTextureSize.width,
            height: previewTextureSize.height
        )
    }
}

@MainActor
func appendPerformanceHUD(to list: DrawList) {
    guard let env = TextEnvironmentHolder.current else { return }

    let now = ProcessInfo.processInfo.systemUptime
    let delta = max(0, now - lastHUDSampleTime)
    lastHUDSampleTime = now
    hudFrameAccum += delta
    hudFrameCount += 1

    if hudFrameAccum >= 0.25 {
        hudFPS = Int((Double(hudFrameCount) / hudFrameAccum).rounded())
        hudFrameMS = (hudFrameAccum / Double(hudFrameCount)) * 1000
        hudFrameAccum = 0
        hudFrameCount = 0
    }

    let hudText = hudFPS > 0
        ? String(format: "FPS %d  %.1f ms", hudFPS, hudFrameMS)
        : "FPS --"
    let font = env.resolvedFont(.system(size: 13, weight: .medium))
    let layout = TextLayout.layout(
        shapedGlyphs: env.shape(text: hudText, font: font),
        text: hudText,
        atlas: env.atlas,
        maxWidth: .infinity,
        lineHeight: env.resolvedLineHeight(font: font, override: nil),
        alignment: .leading
    )

    let panelX: Float = 14
    let panelY: Float = 14
    let paddingX: Float = 10
    let paddingY: Float = 8
    let panelRect = UIRect(
        x: panelX,
        y: panelY,
        width: layout.totalWidth + paddingX * 2,
        height: env.resolvedLineHeight(font: font, override: nil) + paddingY * 2
    )
    list.addRoundedRect(
        panelRect,
        radius: 10,
        color: Color(r: 0.08, g: 0.10, b: 0.13, a: 0.88)
    )
    list.addText(
        layout,
        origin: (panelX + paddingX, panelY + paddingY),
        color: Color(r: 0.90, g: 0.93, b: 0.97, a: 1),
        textureID: env.atlasTextureID
    )
}

host.onInit = { native, w, h in
    drawableW = w; drawableH = h
    logicalW = host.logicalSize.width; logicalH = host.logicalSize.height
    do {
        configureTextEnvironment(scale: host.contentScaleFactor)
        if !didInstallRoot {
            graph.install(root: RootView())
            didInstallRoot = true
        }
        surface = try makeSurface(backend: backend, native: native)
        try surface?.configure(
            device: backend.rawDevice!,
            format: .bgra8Unorm,
            width: w, height: h,
            presentMode: .fifo)
        try renderer.configure(format: .bgra8Unorm)
        try uploadAtlas()
        try uploadPreviewTexture()
        configured = true
    } catch {
        print("[demo] init failed: \(error)")
    }
}

host.onResize = { w, h in
    drawableW = w; drawableH = h
    logicalW = host.logicalSize.width; logicalH = host.logicalSize.height
    guard let surface, let device = backend.rawDevice else { return }
    do {
        try surface.configure(
            device: device, format: .bgra8Unorm,
            width: w, height: h, presentMode: .fifo)
        let previousScale = activeTextScale
        configureTextEnvironment(scale: host.contentScaleFactor)
        if abs(previousScale - activeTextScale) >= 0.01 {
            try uploadAtlas()
            try uploadPreviewTexture()
        }
    } catch {
        print("[demo] resize failed: \(error)")
    }
}

host.onFrame = { _ in
    guard configured, let surface, let root = tree.root else { return }

    let previousScale = activeTextScale
    configureTextEnvironment(scale: host.contentScaleFactor)
    if abs(previousScale - activeTextScale) >= 0.01 {
        do { try uploadPreviewTexture() }
        catch { print("[demo] preview reupload failed: \(error)") }
    }

    // 1. Layout against current viewport. Glyphs are rasterised lazily here as
    //    the measure func runs.
    graph.computeLayout(width: Float(logicalW), height: Float(logicalH))

    // 2. Re-upload atlas in case new glyphs were rasterised this frame.
    do {
        if atlas?.isDirty == true {
            try uploadAtlas()
        }
    } catch {
        print("[demo] atlas reupload failed: \(error)")
    }

    // 3. Walk node tree -> draw list.
    drawList.reset()
    nodeRenderer.render(root: root, into: drawList)
    appendPerformanceHUD(to: drawList)

    // 4. Submit to wgpu.
    let acquired: (texture: GPUTexture, view: GPUTextureView)?
    do {
        acquired = try surface.getCurrentTextureView()
    } catch {
        print("[demo] surface acquire failed: \(error)")
        return
    }
    guard let frame = acquired else { return }

    do {
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(
            colorView: frame.view,
            loadOp: .clear, storeOp: .store,
            clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1)
        )
        try renderer.render(
            list: drawList, pass: pass,
            viewportPx: (drawableW, drawableH),
            coordinateSpace: (Float(logicalW), Float(logicalH)))
        pass.end()
        let buffer = try encoder.finish()
        backend.submit(buffer)
        surface.present()
    } catch {
        print("[demo] frame submit failed: \(error)")
    }
}

host.run(tree: tree)

// MARK: - Surface helper

@MainActor
func makeSurface(backend: WGPUBackend, native: NativeRenderSurface) throws -> GPUSurface {
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
