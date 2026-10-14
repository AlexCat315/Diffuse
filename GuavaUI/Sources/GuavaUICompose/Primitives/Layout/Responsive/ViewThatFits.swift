import Foundation
import GuavaUIScene

/// Switches between two content trees by the width actually available to
/// this container. Unlike `LayoutThatFits`, which rearranges one set of
/// children, each branch owns its own subtree; identity, focus and local
/// state stay separate per branch and survive while that branch is selected.
///
/// The default threshold is the compact width class boundary shared with
/// `UIEnvironment.Viewport.widthClass`, so a component-level switch and the
/// window-level size class agree on what "narrow" means.
///
/// ```swift
/// ViewThatFits {
///     WideToolbar()      // container width ≥ threshold
/// } narrow: {
///     CompactToolbar()   // otherwise
/// }
/// ```
///
/// The first build sees an unmeasured container and selects the narrow
/// branch; the following frame publishes the measured size and rebuilds when
/// the branch changes. Local state is separate per branch: it survives
/// recomposition while that branch stays selected, and resets when the other
/// branch is selected. Compose more than two shapes with
/// `ContainerSizeReader` directly.
public struct ViewThatFits<Wide: View, Narrow: View>: View {
    private let threshold: CGFloat
    private let wide: () -> Wide
    private let narrow: () -> Narrow

    public init(threshold: CGFloat = CGFloat(UIEnvironment.Viewport.compactMaximumWidth),
                @ViewBuilder wide: @escaping () -> Wide,
                @ViewBuilder narrow: @escaping () -> Narrow) {
        self.threshold = threshold.isFinite ? max(0, threshold) : 0
        self.wide = wide
        self.narrow = narrow
    }

    public var body: some View {
        ContainerSizeReader { size in
            if size.width >= threshold {
                wide()
            } else {
                narrow()
            }
        }
    }
}
