import AssetPipeline
import SceneRuntime
import SIMDCompat

/// Evaluates animation clips and computes per-entity `JointPalette` resources.
///
/// Call `tick(context:deltaTime:assetRegistry:)` each frame before scripts execute.
public final class AnimationRuntime: RuntimeScriptDriver, @unchecked Sendable {
    public init() {}

    public func reset() {}

    public func run(context: inout RuntimeScriptPhaseContext) {
        tick(context: &context, deltaTime: context.deltaTimeSeconds)
    }

    public func tick(context: inout RuntimeScriptPhaseContext, deltaTime: Double) {
        var seen: Set<EntityID> = []
        var entities: [EntityID] = []
        for entity in context.entities(with: AnimationGraphPlayer.self) where seen.insert(entity).inserted {
            entities.append(entity)
        }
        for entity in context.entities(with: AnimationPlayer.self) where seen.insert(entity).inserted {
            entities.append(entity)
        }
        var paletteMap = JointPaletteMap()

        for entityID in entities {
            guard let assetRef = context.component(AssetReferenceComponent.self, for: entityID),
                  let mesh = AssetRegistry.shared.meshAsset(for: assetRef.meshIndex),
                  !mesh.animations.isEmpty
            else { continue }

            let pose: AnimationPose?
            if var graphPlayer = context.component(AnimationGraphPlayer.self, for: entityID) {
                pose = evaluateGraph(&graphPlayer, mesh: mesh, deltaTime: deltaTime)
                _ = context.updateComponent(AnimationGraphPlayer.self, for: entityID) { $0 = graphPlayer }
            } else if var player = context.component(AnimationPlayer.self, for: entityID) {
                pose = evaluateSingleClip(&player, mesh: mesh, deltaTime: deltaTime)
                _ = context.updateComponent(AnimationPlayer.self, for: entityID) { $0 = player }
            } else {
                pose = nil
            }

            guard let pose, !mesh.nodes.isEmpty else { continue }
            let worldMatrices = worldMatrices(for: pose, mesh: mesh)

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

    // MARK: - Graph evaluation

    private func evaluateSingleClip(_ player: inout AnimationPlayer,
                                    mesh: MeshAsset,
                                    deltaTime: Double) -> AnimationPose? {
        guard let clip = selectClip(named: player.clipName, in: mesh) else { return nil }
        if player.isPlaying {
            player.time += deltaTime * Double(player.speed)
        }

        let duration = clipDuration(clip)
        if duration > 0 {
            if player.loop {
                player.time = wrapped(player.time, duration: duration)
            } else {
                player.time = Swift.min(player.time, duration)
                if player.time >= duration { player.isPlaying = false }
            }
        }
        return sampleClip(clip, mesh: mesh, time: player.time, loop: player.loop)
    }

    private func evaluateGraph(_ player: inout AnimationGraphPlayer,
                               mesh: MeshAsset,
                               deltaTime: Double) -> AnimationPose? {
        var statesByName: [String: AnimationState] = [:]
        for state in player.graph.stateMachine.states where statesByName[state.name] == nil {
            statesByName[state.name] = state
        }
        guard !statesByName.isEmpty else { return nil }

        if player.activeState.flatMap({ statesByName[$0] }) == nil {
            player.activeState = statesByName[player.graph.stateMachine.initialState] != nil
                ? player.graph.stateMachine.initialState
                : player.graph.stateMachine.states.first?.name
            player.activeTime = 0
            player.previousState = nil
            player.previousTime = 0
            player.transitionElapsed = 0
            player.transitionDuration = 0
        }

        guard let activeName = player.activeState,
              let activeState = statesByName[activeName]
        else { return nil }

        if player.isPlaying {
            player.activeTime += deltaTime * Double(player.speed) * Double(activeState.speed)
            if let previousName = player.previousState,
               let previousState = statesByName[previousName] {
                player.previousTime += deltaTime * Double(player.speed) * Double(previousState.speed)
                player.transitionElapsed += deltaTime
            }
        }

        if player.previousState != nil,
           player.transitionDuration <= 0 || player.transitionElapsed >= player.transitionDuration {
            player.previousState = nil
            player.previousTime = 0
            player.transitionElapsed = 0
            player.transitionDuration = 0
        }

        if player.previousState == nil,
           let transition = player.graph.stateMachine.transitions.first(where: {
               $0.from == activeName && transitionConditionMatches($0, parameters: player.parameters)
           }),
           statesByName[transition.to] != nil {
            player.previousState = activeName
            player.previousTime = player.activeTime
            player.activeState = transition.to
            player.activeTime = 0
            player.transitionElapsed = 0
            player.transitionDuration = transition.duration
            if transition.duration <= 0 {
                player.previousState = nil
                player.previousTime = 0
            }
        }

        guard let currentName = player.activeState,
              let currentState = statesByName[currentName],
              let currentPose = evaluateState(currentState, player: player, mesh: mesh, time: player.activeTime)
        else { return nil }

        guard let previousName = player.previousState,
              let previousState = statesByName[previousName],
              let previousPose = evaluateState(previousState, player: player, mesh: mesh, time: player.previousTime),
              player.transitionDuration > 0
        else { return currentPose }

        let alpha = Float(min(max(player.transitionElapsed / player.transitionDuration, 0), 1))
        return blend(previousPose, currentPose, alpha: alpha)
    }

    private func evaluateState(_ state: AnimationState,
                               player: AnimationGraphPlayer,
                               mesh: MeshAsset,
                               time: Double) -> AnimationPose? {
        switch state.motion {
        case let .clip(clipName):
            guard let clip = selectClip(named: clipName, in: mesh) else { return nil }
            return sampleClip(clip, mesh: mesh, time: normalized(time, duration: clipDuration(clip), loop: state.loop), loop: state.loop)
        case let .blendSpace1D(name):
            guard let blendSpace = player.graph.blendSpaces1D.first(where: { $0.name == name }) else { return nil }
            return evaluateBlendSpace1D(blendSpace, player: player, mesh: mesh, time: time, loop: state.loop)
        }
    }

    private func evaluateBlendSpace1D(_ blendSpace: AnimationBlendSpace1D,
                                      player: AnimationGraphPlayer,
                                      mesh: MeshAsset,
                                      time: Double,
                                      loop: Bool) -> AnimationPose? {
        let samples = blendSpace.samples.sorted { $0.threshold < $1.threshold }
        guard let first = samples.first else { return nil }
        let value = player.parameters[blendSpace.parameter] ?? 0

        if value <= first.threshold {
            return sampleBlendSample(first, mesh: mesh, time: time, loop: loop)
        }
        guard let last = samples.last else { return nil }
        if value >= last.threshold {
            return sampleBlendSample(last, mesh: mesh, time: time, loop: loop)
        }

        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            guard value >= a.threshold && value <= b.threshold else { continue }
            let span = b.threshold - a.threshold
            let alpha = span > 0 ? (value - a.threshold) / span : 0
            guard let pa = sampleBlendSample(a, mesh: mesh, time: time, loop: loop),
                  let pb = sampleBlendSample(b, mesh: mesh, time: time, loop: loop)
            else { return nil }
            return blend(pa, pb, alpha: alpha)
        }
        return nil
    }

    private func sampleBlendSample(_ sample: AnimationBlendSample1D,
                                   mesh: MeshAsset,
                                   time: Double,
                                   loop: Bool) -> AnimationPose? {
        guard let clip = selectClip(named: sample.clipName, in: mesh) else { return nil }
        return sampleClip(clip, mesh: mesh, time: normalized(time, duration: clipDuration(clip), loop: loop), loop: loop)
    }

    private func transitionConditionMatches(_ transition: AnimationTransition,
                                            parameters: [String: Float]) -> Bool {
        let value = parameters[transition.parameter] ?? 0
        switch transition.comparison {
        case .greaterThan: return value > transition.threshold
        case .greaterThanOrEqual: return value >= transition.threshold
        case .lessThan: return value < transition.threshold
        case .lessThanOrEqual: return value <= transition.threshold
        case .equal: return abs(value - transition.threshold) <= 0.0001
        case .notEqual: return abs(value - transition.threshold) > 0.0001
        }
    }

    // MARK: - Sampling

    private func selectClip(named name: String?, in mesh: MeshAsset) -> MeshAnimation? {
        if let name,
           let found = mesh.animations.first(where: { $0.name == name }) {
            return found
        }
        return mesh.animations.first
    }

    private func sampleClip(_ clip: MeshAnimation,
                            mesh: MeshAsset,
                            time: Double,
                            loop: Bool) -> AnimationPose {
        var pose = AnimationPose.bindPose(mesh: mesh)
        let t = Float(normalized(time, duration: clipDuration(clip), loop: loop))

        for channel in clip.channels {
            guard let nodeIdx = channel.targetNodeIndex,
                  mesh.nodes.indices.contains(nodeIdx),
                  clip.samplers.indices.contains(channel.samplerIndex)
            else { continue }
            let sampler = clip.samplers[channel.samplerIndex]
            switch channel.path {
            case .translation: pose.translations[nodeIdx] = sampleVec3(sampler, t)
            case .rotation:    pose.rotations[nodeIdx]    = sampleQuat(sampler, t)
            case .scale:       pose.scales[nodeIdx]       = sampleVec3(sampler, t)
            case .weights:     break
            }
        }

        return pose
    }

    private func clipDuration(_ clip: MeshAnimation) -> Double {
        Double(clip.samplers.compactMap { $0.inputTimes.last }.max() ?? 0)
    }

    private func normalized(_ time: Double, duration: Double, loop: Bool) -> Double {
        guard duration > 0 else { return time }
        return loop ? wrapped(time, duration: duration) : min(max(time, 0), duration)
    }

    private func wrapped(_ time: Double, duration: Double) -> Double {
        guard duration > 0 else { return time }
        var value = time.truncatingRemainder(dividingBy: duration)
        if value < 0 { value += duration }
        return value
    }

    private func sampleVec3(_ sampler: MeshAnimationSampler, _ time: Float) -> SIMD3<Float> {
        let (i0, i1, a) = interval(sampler.inputTimes, time)
        let v0 = xyz(sampler.outputValues[safe: i0] ?? .zero)
        let v1 = xyz(sampler.outputValues[safe: i1] ?? .zero)
        let alpha: Float = sampler.interpolation == .step ? 0 : a
        return v0 * (1 - alpha) + v1 * alpha
    }

    private func sampleQuat(_ sampler: MeshAnimationSampler, _ time: Float) -> SIMD4<Float> {
        let (i0, i1, a) = interval(sampler.inputTimes, time)
        let q0 = sampler.outputValues[safe: i0] ?? SIMD4<Float>(0, 0, 0, 1)
        let q1 = sampler.outputValues[safe: i1] ?? SIMD4<Float>(0, 0, 0, 1)
        let alpha: Float = sampler.interpolation == .step ? 0 : a
        return slerp(q0, q1, alpha)
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

    private func blend(_ a: AnimationPose, _ b: AnimationPose, alpha: Float) -> AnimationPose {
        let count = min(a.translations.count, b.translations.count)
        var translations = a.translations
        var rotations = a.rotations
        var scales = a.scales
        let t = min(max(alpha, 0), 1)
        for i in 0..<count {
            translations[i] = a.translations[i] * (1 - t) + b.translations[i] * t
            rotations[i] = slerp(a.rotations[i], b.rotations[i], t)
            scales[i] = a.scales[i] * (1 - t) + b.scales[i] * t
        }
        return AnimationPose(translations: translations, rotations: rotations, scales: scales)
    }

    private func worldMatrices(for pose: AnimationPose, mesh: MeshAsset) -> [simd_float4x4] {
        // Compute per-node world matrices (parent-before-child order assumed by GLTF).
        var worldMatrices = [simd_float4x4](repeating: matrix_identity_float4x4,
                                            count: mesh.nodes.count)
        for i in mesh.nodes.indices {
            let local = trsMatrix(t: pose.translations[i], r: pose.rotations[i], s: pose.scales[i])
            if let p = mesh.nodes[i].parentIndex, worldMatrices.indices.contains(p) {
                worldMatrices[i] = worldMatrices[p] * local
            } else {
                worldMatrices[i] = local
            }
        }
        return worldMatrices
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

private struct AnimationPose {
    var translations: [SIMD3<Float>]
    var rotations: [SIMD4<Float>]
    var scales: [SIMD3<Float>]

    static func bindPose(mesh: MeshAsset) -> AnimationPose {
        AnimationPose(
            translations: mesh.nodes.map(\.localTranslation),
            rotations: mesh.nodes.map(\.localRotation),
            scales: mesh.nodes.map(\.localScale)
        )
    }
}

private extension Collection {
    subscript(safe i: Index) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
