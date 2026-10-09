import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    func noiseForce(position: SIMD3<Float>, age: Float) -> SIMD3<Float> {
        guard settings.forces.noiseStrength > 0 else { return .zero }
        let p = position * settings.forces.noiseScale
        let phase = age * settings.forces.noiseSpeed + Float(settings.emission.seed & 0xFFFF) * 0.0001
        return SIMD3<Float>(
            sineWave(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719 + phase),
            sineWave(p.y * 26.651 + p.z * 91.191 + p.x * 13.153 + phase + 2.17),
            sineWave(p.z * 54.123 + p.x * 44.531 + p.y * 9.151 + phase + 4.31)
        ) * settings.forces.noiseStrength
    }

    func forceAcceleration(position: SIMD3<Float>) -> SIMD3<Float> {
        guard settings.forces.forceMode != .none, settings.forces.forceStrength != 0 else { return .zero }

        let offset = position - settings.forces.forceCenter
        let distance = simd_length(offset)
        if settings.forces.forceRadius > 0, distance >= settings.forces.forceRadius {
            return .zero
        }

        let attenuation: Float
        if settings.forces.forceRadius > 0 {
            attenuation = pow(max(0, 1 - distance / settings.forces.forceRadius), settings.forces.forceFalloff)
        } else {
            attenuation = 1
        }
        guard attenuation > 0 else { return .zero }

        switch settings.forces.forceMode {
        case .none:
            return .zero
        case .radial:
            guard distance > 0.0001 else { return .zero }
            return (offset / distance) * settings.forces.forceStrength * attenuation
        case .vortex:
            let axis = normalizedOrDefault(settings.forces.forceAxis, SIMD3<Float>(0, 1, 0))
            let planar = offset - axis * simd_dot(offset, axis)
            let planarDistance = simd_length(planar)
            guard planarDistance > 0.0001 else { return .zero }
            let radial = planar / planarDistance
            let tangent = normalizedOrDefault(simd_cross(axis, radial), SIMD3<Float>(0, 0, 1))
            return tangent * settings.forces.forceStrength * attenuation
        }
    }

    func vectorFieldAcceleration(position: SIMD3<Float>, age: Float) -> SIMD3<Float> {
        guard settings.forces.vectorFieldMode != .none, settings.forces.vectorFieldStrength != 0 else { return .zero }
        switch settings.forces.vectorFieldMode {
        case .none:
            return .zero
        case .uniform:
            return normalizedOrDefault(settings.forces.vectorFieldDirection, SIMD3<Float>(0, 1, 0)) * settings.forces.vectorFieldStrength
        case .curl:
            let p = position * settings.forces.vectorFieldScale
            let phase = age * settings.forces.vectorFieldScrollSpeed + Float((settings.emission.seed >> 16) & 0xFFFF) * 0.0001
            let bias = normalizedOrDefault(settings.forces.vectorFieldDirection, SIMD3<Float>(0, 1, 0))
            let field = SIMD3<Float>(
                sineWave(p.y * 8.173 + p.z * 3.117 + phase)
                    - sineWave(p.z * 5.731 + p.x * 7.191 - phase),
                sineWave(p.z * 6.313 + p.x * 4.997 + phase + 1.37)
                    - sineWave(p.x * 9.239 + p.y * 2.173 - phase),
                sineWave(p.x * 4.113 + p.y * 7.911 + phase + 2.71)
                    - sineWave(p.y * 5.337 + p.z * 6.771 - phase)
            )
            let blended = field + bias * 0.25
            return normalizedOrDefault(blended, bias) * settings.forces.vectorFieldStrength
        }
    }

    private func sineWave(_ x: Float) -> Float {
        Float(sin(Double(x)))
    }

    struct ParticleCollisionContext {
        var toWorld: simd_float4x4
        var toLocal: simd_float4x4
    }

    func makeCollisionContext(worldTransform: simd_float4x4?) -> ParticleCollisionContext? {
        guard settings.collision.collisionMode == .worldPlane else { return nil }
        let toWorld = worldTransform ?? matrix_identity_float4x4
        return ParticleCollisionContext(toWorld: toWorld, toLocal: simd_inverse(toWorld))
    }

    func applyCollision(to p: inout Particle, context: ParticleCollisionContext?) -> Bool {
        switch settings.collision.collisionMode {
        case .none:
            return false
        case .localPlane:
            guard p.position.y < settings.collision.collisionPlaneY else { return false }
            p.position.y = settings.collision.collisionPlaneY
            guard p.velocity.y < 0 else { return false }
            p.velocity.y = -p.velocity.y * settings.collision.collisionRestitution
            let tangentScale = 1 - settings.collision.collisionDamping
            p.velocity.x *= tangentScale
            p.velocity.z *= tangentScale
            return true
        case .worldPlane:
            let context = context ?? ParticleCollisionContext(
                toWorld: matrix_identity_float4x4,
                toLocal: matrix_identity_float4x4
            )
            let worldPosition4 = context.toWorld * SIMD4<Float>(p.position, 1)
            guard worldPosition4.y < settings.collision.collisionPlaneY else { return false }

            var clampedWorldPosition = worldPosition4
            clampedWorldPosition.y = settings.collision.collisionPlaneY
            let localPosition4 = context.toLocal * clampedWorldPosition
            if abs(localPosition4.w) > 0.0001 {
                p.position = SIMD3<Float>(
                    localPosition4.x / localPosition4.w,
                    localPosition4.y / localPosition4.w,
                    localPosition4.z / localPosition4.w
                )
            } else {
                p.position = SIMD3<Float>(localPosition4.x, localPosition4.y, localPosition4.z)
            }

            let worldVelocity4 = context.toWorld * SIMD4<Float>(p.velocity, 0)
            guard worldVelocity4.y < 0 else { return false }

            let tangentScale = 1 - settings.collision.collisionDamping
            let bouncedWorldVelocity = SIMD4<Float>(
                worldVelocity4.x * tangentScale,
                -worldVelocity4.y * settings.collision.collisionRestitution,
                worldVelocity4.z * tangentScale,
                0
            )
            let localVelocity4 = context.toLocal * bouncedWorldVelocity
            p.velocity = SIMD3<Float>(localVelocity4.x, localVelocity4.y, localVelocity4.z)
            return true
        }
    }
}
