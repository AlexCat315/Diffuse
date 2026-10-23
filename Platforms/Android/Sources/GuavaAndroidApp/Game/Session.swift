#if GUAVA_ANDROID_GAME
import Foundation
import GameRuntime
import EditorCore
import EngineKernel
import NativeRHI
import RenderBackend
import GuavaUICompose
import GuavaUIRuntime
#if GUAVA_ANDROID_GAME
import GuavaAndroidGameplay
#endif

/// Owns the exported project's simulation and native scene/HUD renderer.
final class GameSession: GameContentSession {
    let application: GameApplication
    private let hud: InGameUIHost
    private(set) var surface = ViewportSurfaceState()
    private var heldKeys: Set<UInt32> = []

    init(device: Device, project: String) throws {
        guard let root = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"],
              project == URL(fileURLWithPath: project).lastPathComponent else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = URL(fileURLWithPath: root).appendingPathComponent(project, isDirectory: true)
        hud = try InGameUIHost(device: device)
        #if GUAVA_ANDROID_GAME
        application = try GameApplication(projectDirectory: directory.path, renderDevice: device, inGameUI: hud,
                                          registerProjectScripts: ProjectGameplay.register)
        #else
        throw RHIError.unsupportedFeature("build this game's APK with guava export game PROJECT --android")
        #endif
        application.bootstrap()
    }

    func prepare(pixels: SIMD2<Int>, scale: Float, deltaTime: Double) {
        application.setViewportDrawableSize(RenderDrawableSize(width: UInt32(pixels.x), height: UInt32(pixels.y)))
        application.tick(deltaTime: deltaTime)
        hud.tick(width: Int(Float(pixels.x) / scale), height: Int(Float(pixels.y) / scale),
                 contentScale: scale, canvas: application.scene.currentInGameCanvas())
        surface = application.currentViewportSurfaceState()
    }

    func key(_ scancode: UInt32, down: Bool) {
        if down { guard heldKeys.insert(scancode).inserted else { return } }
        else { guard heldKeys.remove(scancode) != nil else { return } }
        let event = KeyEvent(scancode: scancode, keycode: 0, modifiers: [], isRepeat: false)
        application.enqueueInput(down ? .keyDown(event) : .keyUp(event))
    }
    func releaseKeys() { for key in Array(heldKeys) { self.key(key, down: false) } }

    func snapshot() -> GameContentSnapshot {
        let manifest = application.scene.manifest()
        let player = manifest.roots.flatMap(flatten).first { $0.name == "Player" }?.localTransform?.rows
        let labels = application.scene.currentInGameCanvas().commands.compactMap { command -> String? in
            if case .label(let text, _, _, _, _) = command { return text }
            return nil
        }
        return GameContentSnapshot(scripts: application.compiledScriptCount, entities: manifest.entityCount,
                        rendered: surface.isValid, surfaceID: surface.surfaceID, hud: labels,
                        player: player.map { [$0[3], $0[7], $0[11]] })
    }

    private func flatten(_ node: EditorSceneManifestNode) -> [EditorSceneManifestNode] { [node] + node.children.flatMap(flatten) }

    deinit {
        application.shutdown()
    }
}

#endif
