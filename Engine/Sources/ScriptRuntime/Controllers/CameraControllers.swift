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
            var move = SIMD3<Float>(input.axis("move_x"), 0, -input.axis("move_y"))
            if input.isHeld("move_forward") { move.z -= 1 }
            if input.isHeld("move_back")    { move.z += 1 }
            if input.isHeld("move_left")    { move.x -= 1 }
            if input.isHeld("move_right")   { move.x += 1 }
            if input.isHeld("move_up")      { move.y += 1 }
            if input.isHeld("move_down")    { move.y -= 1 }

            if simd_length_squared(move) > 0 {
                move = simd_normalize(move)
            }
            let speed = (ctx.floatParameter("moveSpeed") ?? moveSpeed) * Float(ctx.deltaTime)

            // Look
            let sensitivity = ctx.floatParameter("lookSensitivity") ?? lookSensitivity
            let lookX = input.axis("look_x") * sensitivity
            let lookY = input.axis("look_y") * sensitivity

            if let transform = ctx.localTransform {
                let rot = transform.rotation
                let yaw = simd_quatf(angle: -lookX, axis: SIMD3<Float>(0, 1, 0))
                let pitch = simd_quatf(angle: -lookY, axis: SIMD3<Float>(1, 0, 0))
                let newRotation = yaw * rot * pitch

                let forward = newRotation.act(SIMD3<Float>(0, 0, -1))
                let right = newRotation.act(SIMD3<Float>(1, 0, 0))
                let up = SIMD3<Float>(0, 1, 0)
                let translation = transform.translation
                    + forward * move.z * speed
                    + right * move.x * speed
                    + up * move.y * speed

                _ = ctx.setLocalTransform(
                    LocalTransform(matrix: simd_float4x4(newRotation))
                        .withTranslation(translation)
                )
            }
            if let world = ctx.worldTransform,
               ctx.hasComponent(CameraComponent.self) {
                let forwardColumn = SIMD3<Float>(world.matrix.columns.2.x,
                                                 world.matrix.columns.2.y,
                                                 world.matrix.columns.2.z)
                let upColumn = SIMD3<Float>(world.matrix.columns.1.x,
                                            world.matrix.columns.1.y,
                                            world.matrix.columns.1.z)
                let forward = simd_length_squared(forwardColumn) > 0.000_001
                    ? -simd_normalize(forwardColumn)
                    : SIMD3<Float>(0, 0, -1)
                let up = simd_length_squared(upColumn) > 0.000_001
                    ? simd_normalize(upColumn)
                    : SIMD3<Float>(0, 1, 0)
                ctx.updateComponent(CameraComponent.self) { camera in
                    camera.target = world.translation + forward
                    camera.up = up
                }
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
        let initialized = ScriptVar<Bool>(false)

        return Script().onTick { ctx in
            let input = ctx.input

            if !initialized.value {
                dist.value = ctx.floatParameter("distance") ?? distance
                initialized.value = true
            }

            let resolvedOrbitSpeed = ctx.floatParameter("orbitSpeed") ?? orbitSpeed
            let resolvedZoomSpeed = ctx.floatParameter("zoomSpeed") ?? zoomSpeed
            let resolvedMinDistance = ctx.floatParameter("minDistance") ?? minDistance
            let resolvedMaxDistance = max(resolvedMinDistance,
                                          ctx.floatParameter("maxDistance") ?? maxDistance)
            yaw.value -= input.axis("orbit_x") * resolvedOrbitSpeed
            pitch.value -= input.axis("orbit_y") * resolvedOrbitSpeed
            pitch.value = simd_clamp(pitch.value, -.pi/2 + 0.01, .pi/2 - 0.01)
            dist.value -= input.axis("camera_zoom") * resolvedZoomSpeed
            dist.value = simd_clamp(dist.value, resolvedMinDistance, resolvedMaxDistance)

            let rotation = simd_quatf(angle: yaw.value, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: pitch.value, axis: SIMD3<Float>(1, 0, 0))
            let offset = rotation.act(SIMD3<Float>(0, 0, -dist.value))
            let resolvedTarget = ctx.vector3Parameter("target") ?? target
            let position = resolvedTarget + offset

            ctx.setLocalTransform(LocalTransform(matrix: simd_float4x4(rotation))
                .withTranslation(position))
            ctx.updateComponent(CameraComponent.self) { camera in
                camera.target = resolvedTarget
                camera.up = SIMD3<Float>(0, 1, 0)
            }
        }
    }
}
