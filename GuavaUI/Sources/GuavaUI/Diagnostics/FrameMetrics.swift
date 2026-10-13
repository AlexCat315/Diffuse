import Foundation
import GuavaUIRuntime

final class FrameMetrics {
    var fpsFrames = 0
    var fpsWindowStart: Double = 0
    var fpsLayoutAccum = 0.0
    var fpsDrawAccum = 0.0
    var fpsPresentAccum = 0.0
    var fpsTickAccum = 0.0

    /// Accumulate one frame's timing and emit a one-line summary roughly once
    /// per second. `presentMs` covers acquire + encode + submit + present, i.e.
    /// the part that blocks on vsync / GPU / cross-adapter copy.
    func record(layoutMs: Double, drawMs: Double, presentMs: Double) {
        let now = TimingTrace.now()
        if fpsWindowStart == 0 { fpsWindowStart = now }
        fpsFrames += 1
        fpsLayoutAccum += layoutMs
        fpsDrawAccum += drawMs
        fpsPresentAccum += presentMs

        let elapsed = now - fpsWindowStart
        guard elapsed >= 1.0 else { return }
        let n = Double(fpsFrames)
        // Write to stderr: when stdout is redirected to a file it is block
        // buffered, so a force-killed GUI run would lose buffered samples.
        let line = String(format: "[guava.fps] %.1f fps | sim/tick=%.2fms | cpu: layout=%.2fms draw=%.2fms | gpu/present=%.2fms (n=%d)\n",
                          n / elapsed,
                          fpsTickAccum / n,
                          fpsLayoutAccum / n,
                          fpsDrawAccum / n,
                          fpsPresentAccum / n,
                          fpsFrames)
        FileHandle.standardError.write(Data(line.utf8))
        fpsFrames = 0
        fpsWindowStart = now
        fpsLayoutAccum = 0
        fpsDrawAccum = 0
        fpsPresentAccum = 0
        fpsTickAccum = 0
    }

}
