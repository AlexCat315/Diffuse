import Foundation
import GuavaUICompose
import GuavaUIRuntime

@MainActor
final class PerformanceHUD {
    private var sampleTime = TimingTrace.now()
    private var ticks = 0
    private var frames = 0
    private var label = "Render FPS 0  Tick FPS 0"

    func tick() { ticks += 1 }
    func presented() { frames += 1 }

    func draw(into list: DrawList) {
        guard let environment = TextEnvironmentHolder.current else { return }
        let now = TimingTrace.now(), elapsed = now - sampleTime
        if elapsed >= 0.5 {
            label = "Render FPS \(Int((Double(frames) / elapsed).rounded()))  Tick FPS \(Int((Double(ticks) / elapsed).rounded()))"
            ticks = 0; frames = 0; sampleTime = now
        }
        let font = environment.resolvedFont(.system(size: 13, weight: .medium))
        let layout = environment.cachedLayout(text: label, font: font, lineHeight: nil, maxWidth: .infinity, alignment: .leading)
        list.addRoundedRect(UIRect(x: 14, y: 14, width: layout.totalWidth + 20,
            height: environment.resolvedLineHeight(font: font, override: nil) + 16), radius: 10,
            color: Color(r: 0.08, g: 0.10, b: 0.13, a: 0.88))
        list.addText(layout, origin: (24, 22), color: .white,
                     textureID: environment.atlasTextureID, atlas: environment.atlas)
    }
}
