import AssetPipeline
import SceneRuntime
import simd

/// Evaluates animation clips and computes per-entity `JointPalette` resources.
///
/// Call `tick(context:deltaTime:assetRegistry:)` each frame before scripts execute.
final class AnimationRuntime: @unchecked Sendable {

    func tick(context: inout RuntimeScriptPhaseContext, deltaTime: Double) {
        let entities = context.entities(with: AnimationPlayer.self)
        var paletteMap = JointPaletteMap()

        for entityID in entities {
            guard var player = context.component(AnimationPlayer.self, for: entityID),
                  let assetRef = context.component(AssetReferenceComponent.self, for: entityID),
                  let mesh = AssetRegistry.shared.meshAsset(for: assetRef.meshIndex),
                  !mesh.animations.isEmpty
            else { continue }

            if player.isPlaying {
                player.time += deltaTime * Double(player.speed)
            }

            let clip: MeshAnimation
            if let name = player.clipName,
               let found = mesh.animations.first(where: { $0.name == name }) {
                clip = found
            } else if let first = mesh.animations.first {
                clip = first
            } else { continue }

            let duration = Double(clip.samplers.compactMap { $0.inputTimes.last }.max() ?? 0)
            if duration > 0 {
                if player.loop {
                    player.time = player.time.truncatingRemainder(dividingBy: duration)
                    if player.time < 0 { player.time += duration }
                } else {
                    player.time = Swift.min(player.time, duration)
                    if player.time >= duration { player.isPlaying = false }
                }
            }

            _ = context.updateComponent(AnimationPlayer.self, for: entityID) { $0 = player }

            guard !mesh.nodes.isEmpty else { continue }

            var translations = mesh.nodes.map { $0.localTranslation }
            var rotations    = mesh.nodes.map { $0.localRotation }
            var scales       = mesh.nodes.map { $0.localScale }
            let t = Float(player.time)

            for channel in clip.channels {
                guard let nodeIdx = channel.targetNodeIndex,
                      mesh.nodes.indices.contains(nodeIdx),
                      clip.samplers.indices.contains(channel.samplerIndex)
                else { continue }
                let sampler = clip.samplers[channel.samplerIndex]
                switch channel.path {
                case .translation: translations[nodeIdx] = sampleVec3(sampler, t)
                case .rotation:    rotations[nodeIdx]    = sampleQuat(sampler, t)
                case .scale:       scales[nodeIdx]        = sampleVec3(sampler, t)
                case .weights:     break
                }
            }

            // Compute per-node world matrices (parent-before-child order assumed by GLTF)
            var worldMatrices = [simd_float4x4](repeating: matrix_identity_float4x4,
                                               count: mesh.nodes.count)
            for i in mesh.nodes.indices {
                let local = trsMatrix(t: translations[i], r: rotations[i], s: scales[i])
                if let p = mesh.nodes[i].parentIndex, worldMatrices.indices.contains(p) {
                    worldMatrices[i] = worldMatrices[p] * local
                } else {
                    worldMatrices[i] = local
                }
            }

            if let skin = mesh.skins.first {
                var palette = [simd_float4x4]()
                palette.reserveCapacity(skin.jointNodeIndices.count)
                for (j, jointNodeIdx) in skin.jointNodeIndices.enumerated() {
                    let nw = worldMatrices.indices.contains(jointNodeIdx)
                        ? worldMatrices[jointNodeIdx] : matrix_identity_float4x4
                    let ibm = skin.inverseBindMatrices.indices.contains(j)
                        ? skin.inverseBindMatrices[j] : matrix_identity_float4x4
                    palette.append(nw * ibm)
                }
                paletteMap.palettes[entityID] = JointPalette(matrices: palette)
            }
        }

        context.setResource(paletteMap)
    }

    // MARK: - Sampling

    private func sampleVec3(_ sampler: MeshAnimationSampler, _ time: Float) -> SIMD3<Float> {
        let (i0, i1, a) = interval(sampler.inputTimes, time)
        let v0 = xyz(sampler.outputValues[safe: i0] ?? .zero)
        let v1 = xyz(sampler.outputValues[safe: i1] ?? .zero)
        return v0 * (1 - a) + v1 * a
    }

    private func sampleQuat(_ sampler: MeshAnimationSampler, _ time: Float) -> SIMD4<Float> {
        let (i0, i1, a) = interval(sampler.inputTimes, time)
        let q0 = sampler.outputValues[safe: i0] ?? SIMD4<Float>(0, 0, 0, 1)
        let q1 = sampler.outputValues[safe: i1] ?? SIMD4<Float>(0, 0, 0, 1)
        return slerp(q0, q1, a)
    }

    private func interval(_ times: [Float], _ t: Float) -> (Int, Int, Float) {
        guard times.count > 1 else { return (0, 0, 0) }
        if t <= times[0] { return (0, 0, 0) }
        let last = times.count - 1
        if t >= times[last] { return (last, last, 0) }
        var lo = 0; var hi = last
        while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
        let dt = times[hi] - times[lo]
        return (lo, hi, dt > 0 ? (t - times[lo]) / dt : 0)
    }

    private func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3<Float>(v.x, v.y, v.z) }

    private func slerp(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        var cosTheta = dot4(a, b); var b2 = b
        if cosTheta < 0 { b2 = -b2; cosTheta = -cosTheta }
        if cosTheta > 0.9995 { return normQ(a + (b2 - a) * t) }
        let theta = acos(cosTheta); let st = sin(theta)
        return normQ(a * (sin((1 - t) * theta) / st) + b2 * (sin(t * theta) / st))
    }

    private func dot4(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w
    }

    private func normQ(_ q: SIMD4<Float>) -> SIMD4<Float> {
        let l = sqrt(dot4(q, q)); return l > 1e-6 ? q / l : SIMD4<Float>(0, 0, 0, 1)
    }

    private func trsMatrix(t: SIMD3<Float>, r: SIMD4<Float>, s: SIMD3<Float>) -> simd_float4x4 {
        let x2=r.x*r.x; let y2=r.y*r.y; let z2=r.z*r.z
        let xy=r.x*r.y; let xz=r.x*r.z; let yz=r.y*r.z
        let wx=r.w*r.x; let wy=r.w*r.y; let wz=r.w*r.z
        return simd_float4x4(columns: (
            SIMD4<Float>((1-2*(y2+z2))*s.x, 2*(xy+wz)*s.x,    2*(xz-wy)*s.x,   0),
            SIMD4<Float>(2*(xy-wz)*s.y,     (1-2*(x2+z2))*s.y, 2*(yz+wx)*s.y,  0),
            SIMD4<Float>(2*(xz+wy)*s.z,     2*(yz-wx)*s.z,    (1-2*(x2+y2))*s.z, 0),
            SIMD4<Float>(t.x,               t.y,              t.z,              1)
        ))
    }
}

private extension Collection {
    subscript(safe i: Index) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
