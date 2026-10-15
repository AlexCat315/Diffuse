import Foundation
import GuavaUI
import GuavaUIRuntime

struct AnimationSystemExamples: View {
    let isEnabled: Bool
    @State private var run = 0
    @State private var trailing = false
    @State private var looping = false
    @State private var count = 12.0
    @State private var drag = CGPoint.zero
    @State private var expanded = false
    @State private var completed = 0
    private var track: KeyframeTimeline<Float> {
        KeyframeTimeline(initialValue: 1, keyframes: [
            .init(1.12, duration: 0.12, curve: .easeOut),
            .init(0.94, duration: 0.12, curve: .easeInOut), .init(1, duration: 0.16, curve: .easeOut)
        ])
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Tracks & phases", "Play a scale track beside a sequence of domain phases. Both stop when their owning view leaves the tree.") {
                Button("Play sequence", isEnabled: isEnabled) { run += 1 }.debugName("animation-sequence-play")
                Row(alignment: .center, spacing: 24) {
                    KeyframeAnimator(track, trigger: run) { value in
                        Badge("Keyframes", tone: .info).scaleEffect(value).debugName("animation-keyframe")
                    }
                    PhaseAnimator([DemoPhase.idle, .working, .done], trigger: run,
                        animation: { _ in Animation(duration: 0.2, curve: .easeInOut) }) { phase in
                            Badge(phase.rawValue, tone: phase == .done ? .success : .info)
                                .scaleEffect(phase == .working ? 1.08 : 1).debugName("animation-phase")
                        }
                }.frame(height: 58)
                Button(looping ? "Stop loop" : "Start loop", isEnabled: isEnabled) { looping.toggle() }
                    .buttonStyle(.secondary).debugName("animation-loop-toggle")
                if looping && isEnabled {
                    KeyframeAnimator(track, trigger: true, repeating: true) { value in
                        Badge("Repeating", tone: .info).scaleEffect(value)
                    }.frame(height: 40)
                }
            }
            StorySection("Shared geometry", "The selected surface moves and resizes between two layout destinations. Layout reserves its final slot immediately.") {
                Button("Move selection", isEnabled: isEnabled) { trailing.toggle() }.debugName("animation-geometry-move")
                Row(alignment: .center, spacing: 16) {
                    Box(direction: .column, alignItems: .center, justifyContent: .center) {
                        if !trailing { selection(width: 90, height: 28) }
                    }.frame(width: 110, height: 54).background(.surfaceSunken)
                    Box(direction: .column, alignItems: .center, justifyContent: .center) {
                        if trailing { selection(width: 130, height: 44) }
                    }.frame(width: 140, height: 54).background(.surfaceSunken)
                }
            }
            StorySection("Spring release", "Drag the card and release it. The spring receives the measured release velocity; grabbing it again continues at its visible position.") {
                Row(alignment: .center) {
                    Box {}.frame(width: 120, height: 54).background(.accent).cornerRadius(8)
                        .springDrag(offset: $drag, isEnabled: isEnabled).frame(width: 120, height: 54)
                        .debugName("animation-spring-drag")
                }.frame(height: 150)
            }
            StorySection("Numbers & completion", "Numbers interpolate without delaying their accessible value. Completion runs after the animation finishes and is discarded on interruption.") {
                Row(alignment: .center, spacing: 12) {
                    NumericText(count).font(.mono).debugName("animation-number")
                    Button("Add 10", isEnabled: isEnabled) { count += 10 }.debugName("animation-number-add")
                }
                Button("Animate with completion", isEnabled: isEnabled) {
                    withAnimation(Animation(duration: 0.3, curve: .easeInOut), completionCriteria: .removed) {
                        expanded.toggle()
                    } completion: { completed += 1 }
                }.buttonStyle(.secondary).debugName("animation-completion-play")
                Box {}.frame(width: expanded ? 200 : 80, height: 16).background(.accent)
                    .debugName("animation-completion-bar")
                Text("Completed: \(completed)").font(.caption).debugName("animation-completion-count")
            }
        }
    }
    private func selection(width: Float, height: Float) -> some View {
        Box {}.frame(width: width, height: height).background(.accent).cornerRadius(7)
            .debugName("animation-geometry-surface").matchedGeometry("gallery.animation.selection")
    }
}
private enum DemoPhase: String { case idle = "Idle", working = "Working", done = "Done" }
