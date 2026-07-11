import EngineKernel
import SceneRuntime
import SIMDCompat

extension Script {
    /// Maps input actions to the native CharacterVirtual command interface.
    ///
    /// The entity must have a `CharacterController`. Physics behavior remains in
    /// SceneRuntime; this script only owns input mapping. Supported JSON parameters:
    /// `moveSpeed` (5), `jumpSpeed` (8), and `crouchAction` ("crouch").
    public static func characterInputController() -> Script {
        let wasGrounded = ScriptVar<Bool>(false)

        return Script()
            .onPrePhysics { ctx in
                guard ctx.hasComponent(CharacterController.self) else { return }
                let moveSpeed = (ctx.parameters["moveSpeed"] as? Double).map(Float.init) ?? 5
                let jumpSpeed = (ctx.parameters["jumpSpeed"] as? Double).map(Float.init) ?? 8
                let crouchAction = ctx.parameters["crouchAction"] as? String ?? "crouch"

                var direction = SIMD3<Float>.zero
                if ctx.input.isHeld("move_forward") { direction.z -= 1 }
                if ctx.input.isHeld("move_back") { direction.z += 1 }
                if ctx.input.isHeld("move_left") { direction.x -= 1 }
                if ctx.input.isHeld("move_right") { direction.x += 1 }
                if simd_length_squared(direction) > 0 {
                    direction = simd_normalize(direction)
                }

                ctx.submitCharacterCommand(
                    CharacterCommand(
                        desiredVelocity: direction * moveSpeed,
                        jumpRequested: ctx.input.isJustPressed("jump"),
                        jumpSpeed: jumpSpeed,
                        stance: ctx.input.isHeld(crouchAction) ? .crouching : .standing
                    )
                )
            }
            .onUpdate { ctx in
                guard let state = ctx.characterState else { return }
                if state.isGrounded && !wasGrounded.value {
                    ctx.setResource(CharacterLandEvent(entity: ctx.entity))
                } else if !state.isGrounded && wasGrounded.value {
                    ctx.setResource(CharacterLeaveGroundEvent(entity: ctx.entity))
                }
                wasGrounded.value = state.isGrounded
            }
    }
}

public struct CharacterLandEvent: Sendable, Equatable {
    public var entity: EntityID
    public init(entity: EntityID) { self.entity = entity }
}

public struct CharacterLeaveGroundEvent: Sendable, Equatable {
    public var entity: EntityID
    public init(entity: EntityID) { self.entity = entity }
}
