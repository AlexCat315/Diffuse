import GuavaUI
import GuavaUIRuntime

struct AnimationCurveExamples: View {
    let isEnabled: Bool
    @State private var choice = CurveChoice.steps
    @State private var expanded = false

    var body: some View {
        StorySection("Timing curves", "Choose a curve and play in either direction. Steps move in intervals; linear points can plateau and overshoot; bounce and elastic settle after oscillating.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                for value in CurveChoice.allCases {
                    AnyView(Button(value.title, isEnabled: isEnabled, isSelected: choice == value) { choice = value }
                        .buttonStyle(.toggle).debugName("animation-curve-choice-\(value.rawValue)"))
                }
            }
            Button("Play motion", isEnabled: isEnabled) {
                withAnimation(Animation(duration: 1, curve: choice.curve)) { expanded.toggle() }
            }.buttonStyle(.secondary).debugName("animation-curve-play")
            Box(direction: .row, alignItems: .center) {
                Box {}.frame(width: expanded ? 200 : 80, height: 28)
                    .background(.accent).cornerRadius(7).debugName("animation-curve-bar")
            }.frame(height: 64, minWidth: 0).background(.surfaceSunken).cornerRadius(8)
            Text("\(choice.title) · target width \(expanded ? 200 : 80)pt")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

private enum CurveChoice: String, CaseIterable {
    case steps, linear, bounce, elastic
    var title: String {
        switch self {
        case .steps: "Steps"
        case .linear: "Linear points"
        case .bounce: "Bounce out"
        case .elastic: "Elastic out"
        }
    }
    var curve: AnimationCurve {
        switch self {
        case .steps: .steps(5)
        case .linear: .piecewiseLinear(LinearTimingCurve([
            .init(time: 0, progress: 0), .init(time: 0.25, progress: 0.6),
            .init(time: 0.5, progress: 0.6), .init(time: 0.75, progress: 1.2), .init(time: 1, progress: 1)
        ]))
        case .bounce: .bounceOut
        case .elastic: .elasticOut
        }
    }
}
