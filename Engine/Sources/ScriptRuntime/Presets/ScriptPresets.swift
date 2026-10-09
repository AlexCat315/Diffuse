import EngineKernel
import SceneRuntime
import SIMDCompat

public final class ScriptVar<T>: @unchecked Sendable {
    public var value: T
    public init(_ value: T) { self.value = value }
}

extension Script {
    /// Rotates the entity each frame by `speed` (radians/second).
    public static func rotator(speed: SIMD3<Float> = SIMD3<Float>(0, 1.57, 0)) -> Script {
        Script().onTick { ctx in
            let resolvedSpeed = ctx.vector3Parameter("speed") ?? speed
            let delta = resolvedSpeed * Float(ctx.deltaTime)
            let qx = simd_quatf(angle: delta.x, axis: SIMD3<Float>(1, 0, 0))
            let qy = simd_quatf(angle: delta.y, axis: SIMD3<Float>(0, 1, 0))
            let qz = simd_quatf(angle: delta.z, axis: SIMD3<Float>(0, 0, 1))
            let deltaQ = qy * qx * qz
            ctx.updateComponent(LocalTransform.self) { t in
                let newRotation = deltaQ * t.rotation
                t = t.withRotation(newRotation)
            }
        }
    }

    /// Oscillates the entity along `axis` with amplitude and frequency (Hz).
    public static func oscillator(
        axis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        amplitude: Float = 1.0,
        frequency: Float = 1.0
    ) -> Script {
        let elapsed = ScriptVar<Float>(0)
        let base = ScriptVar<SIMD3<Float>?>(nil)
        return Script().onTick { ctx in
            elapsed.value += Float(ctx.deltaTime)
            if base.value == nil {
                base.value = ctx.localTransform?.translation ?? .zero
            }
            guard let b = base.value else { return }
            let resolvedAxis = ctx.vector3Parameter("axis") ?? axis
            let resolvedAmplitude = ctx.floatParameter("amplitude") ?? amplitude
            let resolvedFrequency = ctx.floatParameter("frequency") ?? frequency
            let offset = resolvedAxis
                * (sin(elapsed.value * resolvedFrequency * .pi * 2) * resolvedAmplitude)
            _ = ctx.setLocalTransform(LocalTransform(translation: b + offset))
        }
    }

    /// Smoothly moves toward `target` entity at `speed` (units/sec). Stops within `arrivalRadius`.
    public static func follower(
        target: EntityID,
        speed: Float = 5.0,
        arrivalRadius: Float = 0.1
    ) -> Script {
        Script().onTick { ctx in
            let resolvedTarget = ctx.entityParameter("targetEntityID")
                ?? ctx.stringParameter("targetEntityName").flatMap(ctx.entity(named:))
                ?? (ctx.contains(target) ? target : nil)
            guard let resolvedTarget,
                  let targetWT = ctx.worldTransform(of: resolvedTarget),
                  let myWT = ctx.worldTransform else { return }
            let toTarget = targetWT.translation - myWT.translation
            let dist = simd_length(toTarget)
            let resolvedArrivalRadius = ctx.floatParameter("arrivalRadius") ?? arrivalRadius
            guard dist > resolvedArrivalRadius else { return }
            let resolvedSpeed = ctx.floatParameter("speed") ?? speed
            let step = min(resolvedSpeed * Float(ctx.deltaTime), dist)
            ctx.translate(by: simd_normalize(toTarget) * step)
        }
    }

    /// Rotates to face `target` entity. Forward axis is -Z by default.
    public static func lookAtTarget(
        _ target: EntityID,
        forward: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    ) -> Script {
        Script().onTick { ctx in
            let resolvedTarget = ctx.entityParameter("targetEntityID")
                ?? ctx.stringParameter("targetEntityName").flatMap(ctx.entity(named:))
                ?? (ctx.contains(target) ? target : nil)
            guard let resolvedTarget,
                  let targetWT = ctx.worldTransform(of: resolvedTarget),
                  let myWT = ctx.worldTransform else { return }
            let dir = simd_normalize(targetWT.translation - myWT.translation)
            guard simd_length(dir) > 1e-6 else { return }
            let rot = simd_quatf(from: forward, to: dir)
            ctx.updateComponent(LocalTransform.self) { t in
                t = t.withRotation(rot)
            }
        }
    }

    /// Destroys the entity after `seconds` have elapsed.
    public static func destroyAfter(_ seconds: Double) -> Script {
        let elapsed = ScriptVar<Double>(0)
        return Script().onTick { ctx in
            elapsed.value += ctx.deltaTime
            if elapsed.value >= (ctx.doubleParameter("seconds") ?? seconds) { ctx.destroySelf() }
        }
    }

    /// Moves the entity at constant velocity in world space.
    public static func mover(velocity: SIMD3<Float>) -> Script {
        Script().onTick { ctx in
            let resolvedVelocity = ctx.vector3Parameter("velocity") ?? velocity
            ctx.translate(by: resolvedVelocity * Float(ctx.deltaTime))
        }
    }
}
