import SceneRuntime
import SIMDCompat

/// C ABI functions for the character controller (movement, jump, stance,
/// ground state queries).

/// Submits a character movement command for the entity owning this script.
///
/// - Parameters:
///   - vx, vy, vz: Desired velocity in world units per second.
///   - jump: Whether the character should attempt a jump this frame.
///   - jumpSpeed: Initial upward speed when jumping.
///   - stance: `0` for standing, `1` for crouching.
@_cdecl("guava_submit_character_command")
public func guavaSubmitCharacterCommand(
    _ vx: Float,
    _ vy: Float,
    _ vz: Float,
    _ jump: Bool,
    _ jumpSpeed: Float,
    _ stance: UInt8
) {
    guard let ctx = _guavaCurrentScriptContext else { return }
    let resolvedStance = CharacterStance(rawValue: stance) ?? .standing
    ctx.submitCharacterCommand(CharacterCommand(
        desiredVelocity: SIMD3<Float>(vx, vy, vz),
        jumpRequested: jump,
        jumpSpeed: jumpSpeed,
        stance: resolvedStance
    ))
}

/// Returns whether the owning character is supported by the ground.
@_cdecl("guava_character_is_grounded")
public func guavaCharacterIsGrounded() -> Bool {
    guard let ctx = _guavaCurrentScriptContext,
          let state = ctx.characterState else { return false }
    return state.groundState == .onGround || state.groundState == .onSteepGround
}

/// Returns the raw `CharacterGroundState` raw value, or `0xFF` when unavailable.
///   0 = onGround, 1 = onSteepGround, 2 = notSupported, 3 = inAir
@_cdecl("guava_character_ground_state")
public func guavaCharacterGroundState() -> UInt8 {
    guard let ctx = _guavaCurrentScriptContext,
          let state = ctx.characterState else { return 0xFF }
    return state.groundState.rawValue
}

/// Returns the character's current linear velocity, or zero when unavailable.
@_cdecl("guava_character_velocity")
public func guavaCharacterVelocity(_ outX: UnsafeMutablePointer<Float>,
                                    _ outY: UnsafeMutablePointer<Float>,
                                    _ outZ: UnsafeMutablePointer<Float>) {
    guard let ctx = _guavaCurrentScriptContext,
          let state = ctx.characterState else {
        outX.pointee = 0; outY.pointee = 0; outZ.pointee = 0
        return
    }
    outX.pointee = state.linearVelocity.x
    outY.pointee = state.linearVelocity.y
    outZ.pointee = state.linearVelocity.z
}
