import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    /// UV rect for a particle's current texture sheet frame: x, y, width, height.
    public func textureUVRect(for particle: Particle) -> SIMD4<Float> {
        let columns = max(1, settings.textureSheet.columns)
        let rows = max(1, settings.textureSheet.rows)
        let maxFrames = max(1, columns * rows)
        let frameIndex = textureSheetFrameIndex(for: particle, maxFrames: maxFrames)
        let column = frameIndex % columns
        let row = frameIndex / columns
        let width = 1 / Float(columns)
        let height = 1 / Float(rows)
        return SIMD4<Float>(
            Float(column) * width,
            Float(row) * height,
            width,
            height
        )
    }

    public func textureSheetFrameIndex(for particle: Particle) -> Int {
        let columns = max(1, settings.textureSheet.columns)
        let rows = max(1, settings.textureSheet.rows)
        return textureSheetFrameIndex(for: particle, maxFrames: max(1, columns * rows))
    }

    private func textureSheetFrameIndex(for particle: Particle, maxFrames: Int) -> Int {
        let safeMaxFrames = max(1, maxFrames)
        let startFrame = min(max(0, settings.textureSheet.startFrame), safeMaxFrames - 1)
        let safeFrameCount = min(max(1, settings.textureSheet.frameCount), safeMaxFrames - startFrame)
        let randomRange = max(0, min(settings.textureSheet.frameRandomness, safeFrameCount - 1))
        let randomOffset = randomRange > 0
            ? Int(particle.textureFrameSeed % UInt16(randomRange + 1))
            : 0
        let firstFrame = min(safeFrameCount - 1, randomOffset)

        let advancedFrame: Int
        switch settings.textureSheet.playbackMode {
        case .automatic:
            if settings.textureSheet.frameRate > 0 {
                advancedFrame = Int(floor(max(0, particle.age) * settings.textureSheet.frameRate))
            } else {
                advancedFrame = Int(floor(particle.normalizedAge * Float(safeFrameCount)))
            }
        case .lifetime:
            advancedFrame = Int(floor(particle.normalizedAge * Float(safeFrameCount)))
        case .playOnce:
            let rate = settings.textureSheet.frameRate > 0 ? settings.textureSheet.frameRate : Float(safeFrameCount)
            advancedFrame = Int(floor(max(0, particle.age) * rate))
        case .loop:
            let rate = settings.textureSheet.frameRate > 0 ? settings.textureSheet.frameRate : Float(safeFrameCount)
            advancedFrame = Int(floor(max(0, particle.age) * rate)) % safeFrameCount
        case .singleFrame:
            advancedFrame = 0
        }

        switch settings.textureSheet.playbackMode {
        case .loop:
            return startFrame + ((firstFrame + max(0, advancedFrame)) % safeFrameCount)
        case .singleFrame:
            return startFrame + firstFrame
        case .automatic, .lifetime, .playOnce:
            return startFrame + min(safeFrameCount - 1, firstFrame + max(0, advancedFrame))
        }
    }

    private struct ParticleAppearance {
        var startSize: Float
        var endSize: Float
        var startColor: SIMD4<Float>
        var endColor: SIMD4<Float>
    }

    func refreshAppearance(_ p: inout Particle) {
        let t = p.normalizedAge
        let sizeT = settings.appearance.sizeCurve.evaluate(at: t)
        let colorT = settings.appearance.colorCurve.evaluate(at: t)
        let appearance = appearance(for: p)
        p.size = (appearance.startSize + (appearance.endSize - appearance.startSize) * sizeT) * p.sizeScale
        p.color = appearance.startColor + (appearance.endColor - appearance.startColor) * colorT
    }

    private func appearance(for particle: Particle) -> ParticleAppearance {
        guard particle.appearanceIndex > 0 else {
            return ParticleAppearance(startSize: settings.appearance.startSize,
                                      endSize: settings.appearance.endSize,
                                      startColor: settings.appearance.startColor,
                                      endColor: settings.appearance.endColor)
        }
        if particle.appearanceIndex == 1 {
            return ParticleAppearance(startSize: settings.subEmitters.legacyStartSize,
                                      endSize: settings.subEmitters.legacyEndSize,
                                      startColor: settings.subEmitters.legacyStartColor,
                                      endColor: settings.subEmitters.legacyEndColor)
        }
        let ruleIndex = Int(particle.appearanceIndex) - 2
        if settings.subEmitters.rules.indices.contains(ruleIndex) {
            let rule = settings.subEmitters.rules[ruleIndex]
            return ParticleAppearance(startSize: rule.startSize,
                                      endSize: rule.endSize,
                                      startColor: rule.startColor,
                                      endColor: rule.endColor)
        }
        return ParticleAppearance(startSize: settings.subEmitters.legacyStartSize,
                                  endSize: settings.subEmitters.legacyEndSize,
                                  startColor: settings.subEmitters.legacyStartColor,
                                  endColor: settings.subEmitters.legacyEndColor)
    }

    func textureFrameSeedSnapshot() -> UInt16 {
        UInt16(truncatingIfNeeded: runtime.rngState ^ (runtime.rngState >> 32))
    }
}
