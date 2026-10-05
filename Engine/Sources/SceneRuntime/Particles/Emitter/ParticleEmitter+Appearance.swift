import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    /// UV rect for a particle's current texture sheet frame: x, y, width, height.
    public func textureUVRect(for particle: Particle) -> SIMD4<Float> {
        let columns = max(1, textureSheetColumns)
        let rows = max(1, textureSheetRows)
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
        let columns = max(1, textureSheetColumns)
        let rows = max(1, textureSheetRows)
        return textureSheetFrameIndex(for: particle, maxFrames: max(1, columns * rows))
    }

    private func textureSheetFrameIndex(for particle: Particle, maxFrames: Int) -> Int {
        let safeMaxFrames = max(1, maxFrames)
        let startFrame = min(max(0, textureSheetStartFrame), safeMaxFrames - 1)
        let safeFrameCount = min(max(1, textureSheetFrameCount), safeMaxFrames - startFrame)
        let randomRange = max(0, min(textureSheetFrameRandomness, safeFrameCount - 1))
        let randomOffset = randomRange > 0
            ? Int(particle.textureFrameSeed % UInt16(randomRange + 1))
            : 0
        let firstFrame = min(safeFrameCount - 1, randomOffset)

        let advancedFrame: Int
        switch textureSheetPlaybackMode {
        case .automatic:
            if textureSheetFrameRate > 0 {
                advancedFrame = Int(floor(max(0, particle.age) * textureSheetFrameRate))
            } else {
                advancedFrame = Int(floor(particle.normalizedAge * Float(safeFrameCount)))
            }
        case .lifetime:
            advancedFrame = Int(floor(particle.normalizedAge * Float(safeFrameCount)))
        case .playOnce:
            let rate = textureSheetFrameRate > 0 ? textureSheetFrameRate : Float(safeFrameCount)
            advancedFrame = Int(floor(max(0, particle.age) * rate))
        case .loop:
            let rate = textureSheetFrameRate > 0 ? textureSheetFrameRate : Float(safeFrameCount)
            advancedFrame = Int(floor(max(0, particle.age) * rate)) % safeFrameCount
        case .singleFrame:
            advancedFrame = 0
        }

        switch textureSheetPlaybackMode {
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
        let sizeT = sizeCurve.evaluate(at: t)
        let colorT = colorCurve.evaluate(at: t)
        let appearance = appearance(for: p)
        p.size = (appearance.startSize + (appearance.endSize - appearance.startSize) * sizeT) * p.sizeScale
        p.color = appearance.startColor + (appearance.endColor - appearance.startColor) * colorT
    }

    private func appearance(for particle: Particle) -> ParticleAppearance {
        guard particle.appearanceIndex > 0 else {
            return ParticleAppearance(startSize: startSize,
                                      endSize: endSize,
                                      startColor: startColor,
                                      endColor: endColor)
        }
        if particle.appearanceIndex == 1 {
            return ParticleAppearance(startSize: subEmitterStartSize,
                                      endSize: subEmitterEndSize,
                                      startColor: subEmitterStartColor,
                                      endColor: subEmitterEndColor)
        }
        let ruleIndex = Int(particle.appearanceIndex) - 2
        if subEmitters.indices.contains(ruleIndex) {
            let rule = subEmitters[ruleIndex]
            return ParticleAppearance(startSize: rule.startSize,
                                      endSize: rule.endSize,
                                      startColor: rule.startColor,
                                      endColor: rule.endColor)
        }
        return ParticleAppearance(startSize: subEmitterStartSize,
                                  endSize: subEmitterEndSize,
                                  startColor: subEmitterStartColor,
                                  endColor: subEmitterEndColor)
    }

    func textureFrameSeedSnapshot() -> UInt16 {
        UInt16(truncatingIfNeeded: runtime.rngState ^ (runtime.rngState >> 32))
    }
}
