import EngineKernel
import SceneRuntime
import SIMDCompat

extension Script {
    /// Kinematic character controller: input-driven movement + gravity + ground detection.
    ///
    /// Reads parameters from `ScriptBinding.parametersJSON`:
    /// - `moveSpeed`: Float (default 5.0)
    /// - `jumpSpeed`: Float (default 8.0)
    /// - `gravity`: Float (default 20.0)
    /// - `groundCheckDistance`: Float (default 0.15)
    ///
    /// Expects input actions: "move_forward", "move_back", "move_left", "move_right", "jump".
    /// The entity should have a `Collider` component for ground-check dimensions.
    public static func characterController() -> Script {
        let velocityY = ScriptVar<Float>(0)
        let coyoteTimer = ScriptVar<Float>(0)
        let wasGrounded = ScriptVar<Bool>(false)

        return Script().onTick { ctx in
                let params = ctx.parameters
                let moveSpeed = (params["moveSpeed"] as? Double).map(Float.init) ?? 5.0
                let jumpSpeed = (params["jumpSpeed"] as? Double).map(Float.init) ?? 8.0
                let gravity  = (params["gravity"] as? Double).map(Float.init) ?? 20.0
                let groundCheckDist = (params["groundCheckDistance"] as? Double).map(Float.init) ?? 0.5
                let coyoteMax = (params["coyoteTime"] as? Double).map(Float.init) ?? 0.1

                let dt = Float(ctx.deltaTime)
                let input = ctx.input

                // Determine half-height for ground check ray origin from collider shape.
                let halfHeight: Float = {
                    guard let col = ctx.component(Collider.self) else { return 0.5 }
                    switch col.shape {
                    case let .box(he, _):    return he.y
                    case let .capsule(r, hh, _): return hh + r
                    case let .sphere(r, _):  return r
                    case .mesh, .convex:     return 1.0
                    }
                }()

                guard let pos = ctx.worldTransform?.translation else { return }

                // Ground check: raycast downward from entity origin.
                let rayOrigin = pos + SIMD3<Float>(0, halfHeight, 0)
                let groundHit = ctx.raycast(
                    origin: rayOrigin,
                    direction: SIMD3<Float>(0, -1, 0),
                    maxDistance: halfHeight + groundCheckDist,
                    filter: PhysicsQueryFilter(excludeEntity: ctx.entity)
                )
                let grounded = groundHit != nil && groundHit!.distance <= halfHeight + groundCheckDist

                // Coyote time
                if grounded {
                    coyoteTimer.value = coyoteMax
                } else {
                    coyoteTimer.value = max(0, coyoteTimer.value - dt)
                }
                let canJump = coyoteTimer.value > 0

                // Jump
                let jumpPressed = input.isJustPressed("jump")
                if jumpPressed && canJump {
                    velocityY.value = jumpSpeed
                    coyoteTimer.value = 0
                }

                // Gravity
                if !grounded || velocityY.value > 0 {
                    velocityY.value -= gravity * dt
                } else if grounded && velocityY.value < 0 {
                    velocityY.value = max(velocityY.value, 0)
                }

                // Horizontal movement from input (world-space XZ)
                var move = SIMD3<Float>.zero
                if input.isHeld("move_forward") { move.z -= 1 }
                if input.isHeld("move_back")    { move.z += 1 }
                if input.isHeld("move_left")    { move.x -= 1 }
                if input.isHeld("move_right")   { move.x += 1 }
                if simd_length_squared(move) > 0 { move = simd_normalize(move) }
                let worldMove = SIMD3<Float>(move.x, 0, move.z) * moveSpeed * dt

                // On ground: snap to surface and zero vertical velocity.
                if grounded && velocityY.value <= 0 {
                    let surfaceY = (groundHit?.position.y ?? pos.y) + halfHeight
                    ctx.translate(by: worldMove + SIMD3<Float>(0, surfaceY - pos.y, 0))
                    velocityY.value = 0
                } else {
                    ctx.translate(by: worldMove + SIMD3<Float>(0, velocityY.value * dt, 0))
                }

                // Fire enter/exit ground events for external listeners
                if grounded && !wasGrounded.value {
                    ctx.setResource(CharacterLandEvent(entity: ctx.entity))
                } else if !grounded && wasGrounded.value {
                    ctx.setResource(CharacterLeaveGroundEvent(entity: ctx.entity))
                }
                wasGrounded.value = grounded
            }
    }
}

/// Posted as a resource when a character controller entity lands on the ground.
public struct CharacterLandEvent: Sendable, Equatable {
    public var entity: EntityID
    public init(entity: EntityID) { self.entity = entity }
}

/// Posted as a resource when a character controller entity leaves the ground.
public struct CharacterLeaveGroundEvent: Sendable, Equatable {
    public var entity: EntityID
    public init(entity: EntityID) { self.entity = entity }
}
