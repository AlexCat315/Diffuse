import GuavaAndroidContract
import Foundation
import GuavaUIAndroid
import GuavaUIRuntime
import GuavaUICompose
import NativeRHI
#if GUAVA_ANDROID_UI
import AppContent
#endif

/// Selects application, showcase or game content without owning Compose internals.
@MainActor
final class HostedScene {
    struct Bounds: Codable {
        let x: Float
        let y: Float
        let width: Float
        let height: Float
        init(_ rect: CGRect) {
            x = Float(rect.minX); y = Float(rect.minY)
            width = Float(rect.width); height = Float(rect.height)
        }
    }
    struct Snapshot: Codable {
        let session: String
        let state: [String: String]
        let focused: String?
        let preedit: String
        let controls: [String: Bounds]
        let width: Float
        let height: Float
        let scale: Float
        let typography: TypographyStatistics
        let vertices: Int
        let indices: Int
        let frames: Int
        let mode: String
        let page: String?
        let game: GameContentSnapshot?
        let editor: TextInputClient.Snapshot?
        let nodes: [SemanticNode]
    }
    let launch: SceneLaunch
    #if GUAVA_ANDROID_SHOWCASE
    private let showcase: ShowcaseContent?
    #endif
    let content: AndroidContentSession
    let game: (any GameContentSession)?
    private let gameList = DrawList()
    private var drawing = DrawList()
    private var viewport = SIMD2<Float>.zero
    private var frames = 0
    private let sessionID = UUID().uuidString

    var list: DrawList { game == nil ? drawing : gameList }
    var size: SIMD2<Float> { game == nil ? content.logicalSize : viewport }
    var scale: Float { content.scale }
    var needsFrame: Bool { game != nil || content.needsFrame }
    var focusedID: String? { content.focusedID }
    var hasTextFocus: Bool { content.editorSnapshot != nil || focusedID == "counter.note" }
    var fontAtlas: FontAtlas {
        #if GUAVA_ANDROID_SHOWCASE
        if let atlas = showcase?.typography?.fonts.atlas { return atlas }
        #endif
        return content.fontAtlas
    }
    private var typographyStatistics: TypographyStatistics {
        #if GUAVA_ANDROID_SHOWCASE
        return showcase?.typography?.statistics ?? TypographyStatistics()
        #else
        return TypographyStatistics()
        #endif
    }
    private var currentPage: String? {
        #if GUAVA_ANDROID_SHOWCASE
        return showcase?.page
        #else
        return nil
        #endif
    }
    var editorSnapshot: TextInputClient.Snapshot? {
        if let editor = content.editorSnapshot { return editor }
        guard hasTextFocus else { return nil }
        let value = checkpointState["note", default: ""], preedit = content.preedit
        let caret = value.utf16.count + preedit.utf16.count
        return .init(text: value + preedit, selectionStart: caret, selectionEnd: caret,
                     compositionStart: preedit.isEmpty ? -1 : value.utf16.count, compositionEnd: preedit.isEmpty ? -1 : caret)
    }

    init(checkpoint: String, launch: SceneLaunch, scale: Float, device: Device) throws {
        self.launch = launch
        #if GUAVA_ANDROID_GAME
        game = try launch.mode == .game ? GameSession(device: device, project: launch.project ?? "GuavaProject") : nil
        #else
        guard launch.mode != .game else { throw RHIError.unsupportedFeature("build a game with guava export game PROJECT --android") }
        game = nil
        #endif
        #if GUAVA_ANDROID_SHOWCASE
        showcase = try [.gallery, .counter].contains(launch.mode) ? ShowcaseContent(launch: launch, checkpoint: checkpoint) : nil
        #endif
        let root: AnyView
        switch launch.mode {
        case .gallery, .counter:
            #if GUAVA_ANDROID_SHOWCASE
            root = showcase!.root(scale: scale)
            #else
            throw RHIError.unsupportedFeature("showcase content is not linked into application APKs")
            #endif
        case .application:
            #if GUAVA_ANDROID_UI
            root = AnyView(LayerRoot { makeApplicationContent() })
            #else
            throw RHIError.unsupportedFeature("build this UI application's APK with guava build PATH --android")
            #endif
        case .game: root = AnyView(EmptyView())
        }
        content = AndroidContentSession(scale: scale, rendering: launch.mode == .counter ? .direct : .layers) { root }
    }

    func prepare(pixels: SIMD2<Int>, scale: Float, deltaTime: Double) {
        if let game {
            viewport = SIMD2(Float(pixels.x), Float(pixels.y)) / scale
            game.prepare(pixels: pixels, scale: scale, deltaTime: deltaTime)
            gameList.reset(); gameList.pixelScale = scale
            if game.surface.isValid {
                let uv = game.surface.region.uvMax
                gameList.addImageQuad(rect: UIRect(x: 0, y: 0, width: viewport.x, height: viewport.y), textureID: 2, uvMax: (uv.x, uv.y))
            }
            return
        }
        #if GUAVA_ANDROID_SHOWCASE
        let typography = showcase?.typography
        typography?.beginFrame()
        #endif
        drawing = content.prepare(pixels: pixels, scale: scale, deltaTime: deltaTime)
        #if GUAVA_ANDROID_SHOWCASE
        if typography?.fonts.atlas.isFull == true {
            typography?.fonts.atlas.reset()
            typography?.beginFrame()
            drawing = content.prepare(pixels: pixels, scale: scale, deltaTime: 0)
        }
        typography?.finishFrame()
        #endif
    }

    func didPresent() { frames += 1; content.didPresent() }
    func invalidate() { content.invalidate() }
    func suspend() { content.suspend(); game?.releaseKeys() }
    func pointer(kind: Int32, x: Float, y: Float) { content.pointer(kind: kind, x: x, y: y) }
    func text(_ string: String, composing: Bool) { content.text(string, composing: composing) }
    func edit(kind: Int32, start: Int, end: Int) { content.edit(kind: kind, start: start, end: end) }
    func scroll(x: Float, y: Float, deltaX: Float, deltaY: Float) { content.scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY) }
    func key(_ scancode: UInt32, modifiers: KeyModifiers = []) {
        if let game { game.key(scancode, down: true); game.key(scancode, down: false) }
        else { content.key(scancode, modifiers: modifiers) }
    }
    func snapshot() -> String {
        let inspection = content.inspect()
        let controls = inspection.controls.mapValues(Bounds.init)
        let value = Snapshot(session: sessionID, state: checkpointState,
            focused: focusedID,
            preedit: content.preedit, controls: controls,
            width: size.x, height: size.y, scale: scale, typography: typographyStatistics,
            vertices: list.vertices.count, indices: list.indices.count, frames: frames,
            mode: launch.mode.rawValue, page: currentPage,
            game: game?.snapshot(), editor: editorSnapshot, nodes: semanticNodes(inspection.semantics))
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private var checkpointState: [String: String] {
        #if GUAVA_ANDROID_SHOWCASE
        return showcase?.checkpoint ?? [:]
        #else
        return [:]
        #endif
    }
}
