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
    /// - `groundCheckDistance`: Float (default 0.5)
    /// - `skinWidth`: Float (default 0.02)
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
                let skinWidth = max(0, (params["skinWidth"] as? Double).map(Float.init) ?? 0.02)

                let dt = Float(ctx.deltaTime)
                let input = ctx.input

                let characterShape = characterQueryShape(from: ctx.component(Collider.self))

                guard let pos = ctx.worldTransform?.translation else { return }

                let groundProbeDistance = groundCheckDist + skinWidth
                let groundHit = characterSweepHit(
                    context: ctx,
                    characterShape: characterShape,
                    entityPosition: pos,
                    translation: SIMD3<Float>(0, -groundProbeDistance, 0)
                )
                let touchingGround = groundHit != nil && groundHit!.distance <= groundProbeDistance

                // Coyote time
                if touchingGround && velocityY.value <= 0 {
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
                let grounded = touchingGround && velocityY.value <= 0

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

                let horizontalMove = sweptCharacterTranslation(
                    context: ctx,
                    characterShape: characterShape,
                    entityPosition: pos,
                    translation: worldMove,
                    skinWidth: skinWidth,
                    allowSlide: true
                )
                let horizontalPosition = pos + horizontalMove

                // On ground: snap to the Jolt shape cast contact and zero vertical velocity.
                if grounded && velocityY.value <= 0 {
                    let snapHit = characterSweepHit(
                        context: ctx,
                        characterShape: characterShape,
                        entityPosition: horizontalPosition,
                        translation: SIMD3<Float>(0, -groundProbeDistance, 0)
                    )
                    let snapDistance = max(0, (snapHit?.distance ?? 0) - skinWidth)
                    ctx.translate(by: horizontalMove + SIMD3<Float>(0, -snapDistance, 0))
                    velocityY.value = 0
                } else {
                    let requestedVerticalMove = SIMD3<Float>(0, velocityY.value * dt, 0)
                    let verticalMove = sweptCharacterTranslation(
                        context: ctx,
                        characterShape: characterShape,
                        entityPosition: horizontalPosition,
                        translation: requestedVerticalMove,
                        skinWidth: skinWidth
                    )
                    if verticalMove.y != requestedVerticalMove.y {
                        velocityY.value = 0
                    }
                    ctx.translate(by: horizontalMove + verticalMove)
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

private struct CharacterQueryShape {
    var shape: PhysicsQueryShape
    var center: SIMD3<Float>
    var boxHalfExtents: SIMD3<Float>?
}

private func characterQueryShape(from collider: Collider?) -> CharacterQueryShape {
    guard let collider else {
        return CharacterQueryShape(
            shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5)),
            center: .zero,
            boxHalfExtents: SIMD3<Float>(0.5, 0.5, 0.5)
        )
    }

    switch collider.shape {
    case let .box(halfExtents, center):
        return CharacterQueryShape(
            shape: .box(halfExtents: halfExtents),
            center: center,
            boxHalfExtents: halfExtents
        )
    case let .capsule(radius, halfHeight, center):
        return CharacterQueryShape(shape: .capsule(radius: radius, halfHeight: halfHeight),
                                   center: center,
                                   boxHalfExtents: nil)
    case let .sphere(radius, center):
        return CharacterQueryShape(shape: .sphere(radius: radius),
                                   center: center,
                                   boxHalfExtents: nil)
    case let .mesh(_, center),
         let .convex(_, center):
        let halfExtents = SIMD3<Float>(0.5, 1, 0.5)
        return CharacterQueryShape(
            shape: .box(halfExtents: halfExtents),
            center: center,
            boxHalfExtents: halfExtents
        )
    }
}

private func characterSweepHit(
    context: ScriptContext,
    characterShape: CharacterQueryShape,
    entityPosition: SIMD3<Float>,
    translation: SIMD3<Float>
) -> PhysicsSweepHit? {
    let position = entityPosition + characterShape.center
    let filter = PhysicsQueryFilter(excludeEntity: context.entity)
    if let boxHalfExtents = characterShape.boxHalfExtents {
        return context.physicsSweepAABB(
            PhysicsSweepAABBQuery(
                bounds: SpatialAABB(center: position, halfExtents: boxHalfExtents),
                translation: translation
            ),
            filter: filter
        )
    }
    return context.physicsSweepShape(
        PhysicsSweepShapeQuery(
            shape: characterShape.shape,
            position: position,
            translation: translation
        ),
        filter: filter
    )
}

private func sweptCharacterTranslation(
    context: ScriptContext,
    characterShape: CharacterQueryShape,
    entityPosition: SIMD3<Float>,
    translation: SIMD3<Float>,
    skinWidth: Float,
    allowSlide: Bool = false
) -> SIMD3<Float> {
    let epsilon: Float = 0.000_001
    var remaining = translation
    var moved = SIMD3<Float>.zero
    var origin = entityPosition
    let iterations = allowSlide ? 2 : 1

    for _ in 0..<iterations {
        let distance = simd_length(remaining)
        guard distance > epsilon else { break }

        let hit = characterSweepHit(
            context: context,
            characterShape: characterShape,
            entityPosition: origin,
            translation: remaining
        )
        guard let hit else {
            moved += remaining
            break
        }

        let direction = remaining / distance
        let allowedDistance = min(distance, max(0, hit.distance - skinWidth))
        let allowedMove = direction * allowedDistance
        moved += allowedMove
        origin += allowedMove

        guard allowSlide else { break }

        let unusedDistance = max(0, distance - allowedDistance)
        let normalLengthSquared = simd_length_squared(hit.normal)
        guard unusedDistance > epsilon, normalLengthSquared > epsilon else { break }

        let normal = hit.normal / sqrt(normalLengthSquared)
        let unusedMove = direction * unusedDistance
        let slideMove = unusedMove - normal * simd_dot(unusedMove, normal)
        guard simd_length_squared(slideMove) > epsilon * epsilon else { break }
        remaining = slideMove
    }

    return moved
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
