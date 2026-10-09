import SceneRuntime
import SIMDCompat

/// Layout matches `ParticleSimToInstanceUniforms` in `particle_sim_to_instance.wgsl`.
struct GPUParticleSimulationInstanceUniforms {
    var worldTransform: simd_float4x4
    /// x: particle count, y: base render instance, z: source start index, w: appearance count.
    var params: SIMD4<Float>
    var uvRect: SIMD4<Float>
    /// x: columns, y: rows, z: frame count, w: frame rate.
    var textureSheet: SIMD4<Float>
    /// x: alignment mode (0 billboard, 1 velocity), y: velocity stretch scale, z: max stretch, w: alpha scale.
    var renderParams: SIMD4<Float>
    /// x: trail segments, y: trail length, z: trail end size scale, w: trail end alpha scale.
    var trailParams: SIMD4<Float>
    /// x: playback mode, y: start frame, z: random frame range, w: reserved.
    var textureSheetPlayback: SIMD4<Float>
    /// x/y reserved, z: size curve mode, w: size curve constant.
    var appearanceSize: SIMD4<Float>
    /// Fallback start color when no appearance palette is authored.
    var appearanceStartColor: SIMD4<Float>
    /// Fallback end color when no appearance palette is authored.
    var appearanceEndColor: SIMD4<Float>
    /// x: color curve mode, y: color curve constant, z/w reserved.
    var appearanceColorCurve: SIMD4<Float>
    /// x: size keyframe offset, y: size keyframe count, z: color keyframe offset, w: color keyframe count.
    var curveKeyframes: SIMD4<Float>
}

/// Layout matches `ParticleAppearance` in `particle_sim_to_instance.wgsl`.
struct GPUParticleAppearance {
    /// x: start size, y: end size, z/w reserved.
    var size: SIMD4<Float>
    var startColor: SIMD4<Float>
    var endColor: SIMD4<Float>
}

/// Layout matches `ParticleCurveKeyframe` in `particle_sim_to_instance.wgsl`.
struct GPUParticleCurveKeyframe {
    /// x: normalized time, y: value, z/w reserved.
    var timeValue: SIMD4<Float>
}

struct GPUParticleCurveEncoding {
    var modeConstant: SIMD2<Float>
    var keyframeRange: SIMD2<Float>
}

/// Layout matches `ParticleSortPrepareUniforms` in `particle_sort_prepare.wgsl`.
struct GPUParticleSortPrepareUniforms {
    var worldTransform: simd_float4x4
    /// x: render particle count, y: source start index, z: sort mode, w: padded sort capacity.
    var params: SIMD4<Float>
    /// xyz: camera eye used by distance sort modes.
    var sortParams: SIMD4<Float>
}

/// Layout matches `ParticleSortBitonicUniforms` in `particle_sort_bitonic.wgsl`.
struct GPUParticleSortBitonicUniforms {
    /// x: sort capacity, y: bitonic k, z: bitonic j.
    var params: SIMD4<UInt32>
}

/// Layout matches `ParticleSortItem` in particle sort WGSL shaders.
struct GPUParticleSortItem {
    var key: Float
    var index: UInt32
    var _padding0: UInt32 = 0
    var _padding1: UInt32 = 0
}

struct GPUParticleSimulationSortEncodeReport {
    var passCount: Int
    var itemCount: Int
    var paddedItemCount: Int
    var dispatchWorkgroups: Int
}

struct GPUParticleSimulationInstanceEncodeReport {
    var renderInstanceCount: Int
    var instanceDispatchWorkgroups: Int
    var sortReport: GPUParticleSimulationSortEncodeReport
}

extension GPUParticleCurveEncoding {
    static func encode(_ curve: ParticleCurve,
                                  keyframes: inout [GPUParticleCurveKeyframe]) -> GPUParticleCurveEncoding {
        switch curve {
        case .constant(let value):
            return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(1, value),
                                            keyframeRange: .zero)
        case .linear:
            return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(2, 0),
                                            keyframeRange: .zero)
        case .easeIn:
            return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(3, 0),
                                            keyframeRange: .zero)
        case .easeOut:
            return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(4, 0),
                                            keyframeRange: .zero)
        case .easeInOut:
            return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(5, 0),
                                            keyframeRange: .zero)
        case .keyframes(let frames):
            guard !frames.isEmpty else {
                return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(2, 0),
                                                keyframeRange: .zero)
            }
            let sorted = frames.enumerated()
                .sorted {
                    if $0.element.time == $1.element.time {
                        return $0.offset < $1.offset
                    }
                    return $0.element.time < $1.element.time
                }
                .map(\.element)
            let offset = keyframes.count
            let remaining = max(0, GPUParticleAppearanceData.keyframeCapacity - offset)
            guard remaining > 0 else {
                return GPUParticleCurveEncoding(modeConstant: SIMD2<Float>(0, 0),
                                                keyframeRange: .zero)
            }
            var selected = Array(sorted.prefix(remaining))
            if sorted.count > remaining,
               let last = sorted.last,
               !selected.isEmpty {
                selected[selected.count - 1] = last
            }
            for frame in selected {
                keyframes.append(
                    GPUParticleCurveKeyframe(
                        timeValue: SIMD4<Float>(frame.time, frame.value, 0, 0)
                    )
                )
            }
            return GPUParticleCurveEncoding(
                modeConstant: SIMD2<Float>(6, 0),
                keyframeRange: SIMD2<Float>(Float(offset), Float(selected.count))
            )
        }
    }

}

struct GPUParticleAppearanceData {
    static let appearanceCapacity = 64
    static let keyframeCapacity = 128
    var appearances: [GPUParticleAppearance]
    var keyframes: [GPUParticleCurveKeyframe] = []
    var sizeCurve: GPUParticleCurveEncoding
    var colorCurve: GPUParticleCurveEncoding
    init(batch: RenderParticleSimulationBatch) {
        appearances = Self.packAppearances(for: batch)
        sizeCurve = GPUParticleCurveEncoding.encode(batch.sizeCurve,keyframes: &keyframes)
        colorCurve = GPUParticleCurveEncoding.encode(batch.colorCurve,keyframes: &keyframes)
    }
    private static func packAppearances(for batch: RenderParticleSimulationBatch) -> [GPUParticleAppearance] {
        let fallbackAppearance = RenderParticleAppearance(startSize: batch.startSize,
                                                         endSize: batch.endSize,
                                                         startColor: batch.startColor,
                                                         endColor: batch.endColor)
        let palette = batch.appearancePalette.isEmpty ? [fallbackAppearance] : batch.appearancePalette
        var result = [GPUParticleAppearance]()
        result.reserveCapacity(appearanceCapacity)
        for appearance in palette.prefix(appearanceCapacity) {
            result.append(
                GPUParticleAppearance(
                    size: SIMD4<Float>(appearance.startSize, appearance.endSize, 0, 0),
                    startColor: appearance.startColor,
                    endColor: appearance.endColor
                )
            )
        }
        if result.isEmpty {
            result.append(
                GPUParticleAppearance(
                    size: SIMD4<Float>(fallbackAppearance.startSize, fallbackAppearance.endSize, 0, 0),
                    startColor: fallbackAppearance.startColor,
                    endColor: fallbackAppearance.endColor
                )
            )
        }
        return result
    }

}

extension GPUParticleSimulationInstanceUniforms {
    var isFinite: Bool { withUnsafeBytes(of: self) { $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) } }
    init(batch: RenderParticleSimulationBatch, baseInstance: Int, appearance: GPUParticleAppearanceData) {
        worldTransform = batch.worldTransform
        params = SIMD4(Float(batch.renderParticleCount),Float(baseInstance),Float(batch.renderParticleStartIndex),Float(appearance.appearances.count))
        uvRect = batch.uvRect
        textureSheet = SIMD4(Float(batch.textureSheetColumns),Float(batch.textureSheetRows),Float(batch.textureSheetFrameCount),batch.textureSheetFrameRate)
        renderParams = SIMD4(batch.renderAlignment == .velocity ? 1 : 0,batch.velocityStretchScale,batch.velocityStretchMax,batch.renderAlphaScale)
        trailParams = SIMD4(Float(max(0,batch.trailSegments)),batch.trailLength,batch.trailEndSizeScale,batch.trailEndAlphaScale)
        let playback: Float = switch batch.textureSheetPlaybackMode { case .automatic: 0; case .lifetime: 1; case .playOnce: 2; case .loop: 3; case .singleFrame: 4 }
        textureSheetPlayback = SIMD4(playback,Float(batch.textureSheetStartFrame),Float(batch.textureSheetFrameRandomness),0)
        appearanceSize = SIMD4(0,0,appearance.sizeCurve.modeConstant.x,appearance.sizeCurve.modeConstant.y)
        appearanceStartColor = batch.startColor; appearanceEndColor = batch.endColor
        appearanceColorCurve = SIMD4(appearance.colorCurve.modeConstant.x,appearance.colorCurve.modeConstant.y,batch.usesAuthoredAppearance ? 1 : 0,0)
        curveKeyframes = SIMD4(appearance.sizeCurve.keyframeRange.x,appearance.sizeCurve.keyframeRange.y,appearance.colorCurve.keyframeRange.x,appearance.colorCurve.keyframeRange.y)
    }
}

extension GPUParticleSortPrepareUniforms {
    init(batch: RenderParticleSimulationBatch, cameraEye: SIMD3<Float>, capacity: Int) {
        worldTransform = batch.worldTransform
        let mode: Float = switch batch.sortMode { case .distanceDescending: 0; case .distanceAscending: 1; case .oldestFirst: 2; case .youngestFirst: 3 }
        params = SIMD4(Float(batch.renderParticleCount),Float(batch.renderParticleStartIndex),mode,Float(capacity))
        sortParams = SIMD4(cameraEye,0)
    }
}

struct GPUParticleSortStage {
    let k: Int
    let j: Int
    func uniforms(capacity: Int) -> GPUParticleSortBitonicUniforms {
        GPUParticleSortBitonicUniforms(params: SIMD4(UInt32(capacity),UInt32(k),UInt32(j),0))
    }
}

/// One bitonic network is shared by both rendering backends.
struct GPUParticleSortPlan {
    let capacity: Int
    var stages: [GPUParticleSortStage] = []
    init(count: Int) {
        capacity = Self.capacity(for: count)
        var k = 2
        while k <= capacity {
            var j = k/2
            while j > 0 { stages.append(GPUParticleSortStage(k: k,j: j)); j /= 2 }
            k *= 2
        }
    }
    static func capacity(for count: Int) -> Int {
        var value = 1
        while value < max(1,count) { value <<= 1 }
        return value
    }
}

extension GPUParticleAppearanceData {
    var isFinite: Bool {
        appearances.withUnsafeBytes { $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) }
            && keyframes.withUnsafeBytes { $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) }
    }
}
