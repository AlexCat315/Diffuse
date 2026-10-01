import GuavaUIRuntime

/// Compatibility facade using the shared AnimatedVisibility lifecycle.
public struct TransitionView<Content: View>: View {
    private let visible: Bool
    private let transition: Transition
    private let motion: SemanticMotionRef
    private let content: Content

    public init(isVisible: Bool, transition: Transition = .opacity,
                removal: Transition? = nil, motion: SemanticMotionRef = .medium,
                @ViewBuilder content: () -> Content) {
        visible = isVisible
        self.transition = .asymmetric(insertion: transition, removal: removal ?? transition)
        self.motion = motion
        self.content = content()
    }

    public var body: some View {
        ThemeReader { theme in
            AnimatedVisibility(isVisible: visible, transition: transition,
                               animation: motion.resolve(theme), animateOnMount: true) { content }
        }
    }
}
