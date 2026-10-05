import Foundation
import EngineKernel
import SceneRuntime
import ScriptRuntime
import SIMDCompat

/// Crystal Rush: a complete tiny game using Guava's real input, scene and HUD.
struct GameScript: ScriptBehavior {
    private var player: EntityID?
    private var gems: [EntityID] = []
    private var enemies: [EntityID] = []
    private var collected: Set<Int> = []
    private var phase = "ready"
    private var remaining: Float = 50
    private var hearts = 3
    private var elapsed: Float = 0
    private var invulnerability: Float = 0
    private let gemPositions: [SIMD3<Float>] = [
        SIMD3(-7, 0.65, -4), SIMD3(-3, 0.65, -4), SIMD3(3, 0.65, -4), SIMD3(7, 0.65, -4),
        SIMD3(-7, 0.65, 4), SIMD3(-3, 0.65, 4), SIMD3(3, 0.65, 4), SIMD3(7, 0.65, 4),
    ]

    mutating func onStart(_ context: ScriptContext) {
        var input = InputActionMap.guavaDefault
        input.bind("start", to: .key(Scancode.space))
        input.bind("restart", to: .key(Scancode.r))
        input.bind("sprint", to: .key(Scancode.lshift))
        context.setResource(input)

        let camera = context.createEntity(named: "Camera", transform: LocalTransform(translation: SIMD3(0, 19, 18)))
        context.setComponent(CameraComponent(target: SIMD3(0, 0, 0), fovYRadians: .pi / 3.5, near: 0.1, far: 100), for: camera)
        let sun = context.createEntity(named: "Sun", transform: LocalTransform(
            rotation: simd_quatf(angle: -.pi / 3, axis: SIMD3(1, 0, 0))))
        context.setComponent(LightComponent(type: .directional, intensity: 3, castShadows: true), for: sun)
        let fill = context.createEntity(named: "Fill", transform: LocalTransform(translation: SIMD3(0, 7, 0)))
        context.setComponent(LightComponent(type: .point, color: SIMD3(0.25, 0.55, 1), intensity: 55, range: 28), for: fill)

        _ = cube(context, "Arena", at: SIMD3(0, -0.2, 0), scale: SIMD3(18, 0.3, 14), color: SIMD3(0.035, 0.055, 0.1))
        for x in -4...4 {
            for z in -3...3 where (x + z) % 2 == 0 {
                _ = cube(context, "Tile", at: SIMD3(Float(x) * 2, -0.02, Float(z) * 2),
                         scale: SIMD3(1.92, 0.02, 1.92), color: SIMD3(0.06, 0.10, 0.16))
            }
        }
        for z: Float in [-7, 7] {
            _ = cube(context, "Boundary", at: SIMD3(0, 0.05, z), scale: SIMD3(18, 0.2, 0.18),
                     color: SIMD3(0.1, 0.8, 0.9), glow: SIMD3(0.04, 0.35, 0.5))
        }
        for x: Float in [-9, 9] {
            _ = cube(context, "Boundary", at: SIMD3(x, 0.05, 0), scale: SIMD3(0.18, 0.2, 14),
                     color: SIMD3(0.1, 0.8, 0.9), glow: SIMD3(0.04, 0.35, 0.5))
        }
        player = cube(context, "Player", at: SIMD3(0, 0.6, 0), scale: SIMD3(0.8, 1.1, 0.8),
                      color: SIMD3(0.3, 0.85, 1), glow: SIMD3(0.03, 0.2, 0.3))
        if let player { context.setComponent(Collider(shape: .sphere(radius: 0.45, center: .zero)), for: player) }
        for (index, position) in gemPositions.enumerated() {
            let gem = cube(context, "Crystal \(index + 1)", at: position, scale: SIMD3(repeating: 0.55),
                           color: SIMD3(0.8, 1, 0.25), glow: SIMD3(0.2, 0.45, 0.015))
            context.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero), isTrigger: true), for: gem)
            gems.append(gem)
            _ = cube(context, "Crystal Pad", at: SIMD3(position.x, 0.04, position.z), scale: SIMD3(1.1, 0.07, 1.1),
                     color: SIMD3(0.08, 0.23, 0.18))
        }
        for index in 0..<3 {
            enemies.append(cube(context, "Sentinel \(index + 1)", at: SIMD3(0, 0.7, 0),
                                scale: SIMD3(1.1, 1.3, 1.1), color: SIMD3(1, 0.18, 0.3), glow: SIMD3(0.3, 0.015, 0.03)))
        }
        // A harness can start immediately using JSON parameters; interactive play
        // defaults to a start screen so the timer never runs before the user is ready.
        if context.stringParameter("startMode") == "playing" { phase = "playing" }
        updateWorld(context)
        drawHUD(context)
    }

    mutating func onUpdate(_ context: ScriptContext) {
        let dt = min(0.05, max(0, Float(context.deltaTime)))
        if context.input.isJustPressed("restart") { restart(context) }
        if phase == "ready", context.input.isJustPressed("start") { phase = "playing" }
        if phase == "playing", let player, var transform = context.localTransform(of: player) {
            elapsed += dt
            remaining = max(0, remaining - dt)
            invulnerability = max(0, invulnerability - dt)
            var movement = SIMD3<Float>(context.input.axis("move_x"), 0, -context.input.axis("move_y"))
            let magnitude = simd_length(movement)
            if magnitude > 1 { movement /= magnitude }
            let speed: Float = context.input.isHeld("sprint") ? 7 : 4.5
            transform.translation += movement * speed * dt
            transform.translation.x = max(-8.25, min(8.25, transform.translation.x))
            transform.translation.z = max(-6.25, min(6.25, transform.translation.z))
            context.setLocalTransform(transform, for: player)
            for (index, position) in gemPositions.enumerated() where !collected.contains(index) {
                if planarDistance(transform.translation, position) < 0.85 {
                    collected.insert(index)
                    if var mesh = context.component(RenderMeshComponent.self, for: gems[index]) {
                        mesh.isVisible = false
                        context.setComponent(mesh, for: gems[index])
                    }
                }
            }
            for (index, _) in enemies.enumerated() where invulnerability <= 0 {
                if planarDistance(transform.translation, enemyPosition(index)) < 0.95 {
                    hearts -= 1
                    invulnerability = 1.4
                }
            }
            if collected.count == gems.count { phase = "won" }
            else if hearts <= 0 || remaining <= 0 { phase = "lost" }
        }
        updateWorld(context)
        drawHUD(context)
        let position = player.flatMap { context.localTransform(of: $0)?.translation } ?? .zero
        context.reportState([
            "game": "Crystal Rush", "phase": phase, "score": "\(collected.count)", "target": "8",
            "hearts": "\(hearts)", "remaining_seconds": String(format: "%.2f", remaining),
            "player_x": "\(position.x)", "player_z": "\(position.z)",
        ])
    }

    private mutating func restart(_ context: ScriptContext) {
        phase = "playing"; collected = []; hearts = 3; remaining = 50; elapsed = 0; invulnerability = 0
        if let player { context.setLocalTransform(LocalTransform(translation: SIMD3(0, 0.6, 0), scale: SIMD3(0.8, 1.1, 0.8)), for: player) }
        for gem in gems {
            if var mesh = context.component(RenderMeshComponent.self, for: gem) {
                mesh.isVisible = true
                context.setComponent(mesh, for: gem)
            }
        }
    }

    private func enemyPosition(_ index: Int) -> SIMD3<Float> {
        let angle = elapsed * (0.65 + Float(index) * 0.1) + Float(index) * 2.1
        return SIMD3(sin(angle) * (4 + Float(index)), 0.7, cos(angle * 0.85) * 3)
    }

    private func updateWorld(_ context: ScriptContext) {
        for (index, enemy) in enemies.enumerated() {
            context.setLocalTransform(LocalTransform(translation: enemyPosition(index),
                rotation: simd_quatf(angle: elapsed + Float(index), axis: SIMD3(0, 1, 0)), scale: SIMD3(1.1, 1.3, 1.1)), for: enemy)
        }
        for (index, gem) in gems.enumerated() where !collected.contains(index) {
            var position = gemPositions[index]
            position.y += sin(elapsed * 3 + Float(index)) * 0.13
            context.setLocalTransform(LocalTransform(translation: position,
                rotation: simd_quatf(angle: elapsed * 1.5 + Float(index) * 0.3, axis: simd_normalize(SIMD3<Float>(0.4, 1, 0.2))),
                scale: SIMD3(repeating: 0.55)), for: gem)
        }
        if let player, var mesh = context.component(RenderMeshComponent.self, for: player) {
            mesh.isVisible = invulnerability <= 0 || Int(invulnerability * 10) % 2 == 0
            context.setComponent(mesh, for: player)
        }
    }

    private func drawHUD(_ context: ScriptContext) {
        context.drawUI { canvas in
            let muted = InGameUIColor(r: 0.6, g: 0.72, b: 0.85)
            let cyan = InGameUIColor(r: 0.35, g: 0.88, b: 1)
            canvas.rect(x: 24, y: 24, w: 346, h: 136, color: InGameUIColor(r: 0.015, g: 0.025, b: 0.06, a: 0.94), cornerRadius: 14)
            canvas.label("CRYSTAL RUSH", x: 42, y: 38, fontSize: 24, color: cyan)
            canvas.label("晶体 \(collected.count) / 8    生命 \(String(repeating: "♥", count: max(0, hearts)))", x: 42, y: 76, fontSize: 20)
            canvas.label("剩余时间  \(Int(ceil(remaining))) 秒", x: 42, y: 108, fontSize: 15, color: muted)
            canvas.progressBar(x: 42, y: 140, w: 308, h: 5, value: remaining, maxValue: 50, fillColor: cyan)
            canvas.rect(x: 24, y: 172, w: 346, h: 66, color: InGameUIColor(r: 0.015, g: 0.025, b: 0.06, a: 0.85), cornerRadius: 10)
            canvas.label("WASD 移动  ·  Shift 加速", x: 42, y: 185, fontSize: 16, color: muted)
            canvas.label("收集绿色晶体，避开红色守卫  ·  R 重开", x: 42, y: 208, fontSize: 14, color: muted)
            if phase != "playing" {
                canvas.rect(x: 24, y: 254, w: 346, h: 152, color: InGameUIColor(r: 0.015, g: 0.035, b: 0.08, a: 0.96), cornerRadius: 14)
                let title = phase == "ready" ? "准备好了吗？" : (phase == "won" ? "全部收集！你赢了" : "挑战结束")
                canvas.label(title, x: 42, y: 278, fontSize: 28, color: phase == "lost" ? .red : cyan)
                canvas.label(phase == "ready" ? "50 秒内收集 8 块晶体。" : "最终成绩：\(collected.count) / 8 块晶体", x: 42, y: 322, fontSize: 18)
                canvas.label(phase == "ready" ? "按空格开始" : "按 R 再玩一次", x: 42, y: 363, fontSize: 20, color: cyan)
            }
        }
    }

    @discardableResult
    private func cube(_ context: ScriptContext, _ name: String, at position: SIMD3<Float>,
                      scale: SIMD3<Float>, color: SIMD3<Float>, glow: SIMD3<Float> = .zero) -> EntityID {
        let entity = context.createEntity(named: name, transform: LocalTransform(translation: position, scale: scale))
        context.setComponent(RenderMeshComponent(meshIndex: 0, colorTint: color), for: entity)
        context.setComponent(RenderMaterialComponent(roughnessFactor: 0.72, emissiveFactor: glow), for: entity)
        return entity
    }

    private func planarDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2<Float>(a.x - b.x, a.z - b.z))
    }
}
