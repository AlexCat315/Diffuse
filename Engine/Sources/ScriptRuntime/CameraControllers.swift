import EngineKernel
import SceneRuntime
import SIMDCompat

extension Script {
    /// First-person camera: WASD movement + mouse look.
    /// Expects input actions: "move_forward", "move_back", "move_left", "move_right",
    /// "move_up", "move_down", "look_x", "look_y".
    public static func firstPersonCamera(
        moveSpeed: Float = 5.0,
        lookSensitivity: Float = 0.002
    ) -> Script {
        Script().onTick { ctx in
            let input = ctx.input

            // Movement
            var move = SIMD3<Float>.zero
            if input.isHeld("move_forward") { move.z -= 1 }
            if input.isHeld("move_back")    { move.z += 1 }
            if input.isHeld("move_left")    { move.x -= 1 }
            if input.isHeld("move_right")   { move.x += 1 }
            if input.isHeld("move_up")      { move.y += 1 }
            if input.isHeld("move_down")    { move.y -= 1 }

            if simd_length_squared(move) > 0 {
                move = simd_normalize(move)
            }
            let speed = moveSpeed * Float(ctx.deltaTime)

            // Look
            let lookX = input.axis("look_x") * lookSensitivity
            let lookY = input.axis("look_y") * lookSensitivity

            ctx.updateComponent(LocalTransform.self) { t in
                let rot = t.rotation
                let yaw = simd_quatf(angle: -lookX, axis: SIMD3<Float>(0, 1, 0))
                let pitch = simd_quatf(angle: -lookY, axis: SIMD3<Float>(1, 0, 0))
                let newRotation = yaw * rot * pitch

                let forward = newRotation.act(SIMD3<Float>(0, 0, -1))
                let right = newRotation.act(SIMD3<Float>(1, 0, 0))
                let up = SIMD3<Float>(0, 1, 0)
                let translation = t.translation
                    + forward * move.z * speed
                    + right * move.x * speed
                    + up * move.y * speed

                t = LocalTransform(matrix: simd_float4x4(newRotation))
                    .withTranslation(translation)
            }
        }
    }

    /// Orbit camera: rotates around a target point. Mouse drag orbits, scroll zooms.
    /// Expects input actions: "orbit_x", "orbit_y", "camera_zoom".
    public static func orbitCamera(
        target: SIMD3<Float> = .zero,
        distance: Float = 10.0,
        orbitSpeed: Float = 0.005,
        zoomSpeed: Float = 1.0,
        minDistance: Float = 1.0,
        maxDistance: Float = 100.0
    ) -> Script {
        let yaw = ScriptVar<Float>(0)
        let pitch = ScriptVar<Float>(.pi / 6)
        let dist = ScriptVar<Float>(distance)

        return Script().onTick { ctx in
            let input = ctx.input

            yaw.value -= input.axis("orbit_x") * orbitSpeed
            pitch.value -= input.axis("orbit_y") * orbitSpeed
            pitch.value = simd_clamp(pitch.value, -.pi/2 + 0.01, .pi/2 - 0.01)
            dist.value -= input.axis("camera_zoom") * zoomSpeed * Float(ctx.deltaTime)
            dist.value = simd_clamp(dist.value, minDistance, maxDistance)

            let rotation = simd_quatf(angle: yaw.value, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: pitch.value, axis: SIMD3<Float>(1, 0, 0))
            let offset = rotation.act(SIMD3<Float>(0, 0, -dist.value))
            let position = target + offset

            ctx.setLocalTransform(LocalTransform(matrix: simd_float4x4(rotation))
                .withTranslation(position))
        }
    }
}
