import GuavaUIRuntime

public struct SplitView<First: View, Second: View>: View {
    public enum Axis {
        case horizontal
        case vertical
    }

    public let axis: Axis
    public let fraction: Float
    public let spacing: Float
    public let dividerThickness: Float
    public let dividerColor: Color?
    public let first: First
    public let second: Second

    public init(_ axis: Axis = .horizontal,
                fraction: Float = 0.5,
                spacing: Float = 0,
                dividerThickness: Float = 1,
                dividerColor: Color? = nil,
                @ViewBuilder first: () -> First,
                @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.fraction = fraction
        self.spacing = spacing
        self.dividerThickness = dividerThickness
        self.dividerColor = dividerColor
        self.first = first()
        self.second = second()
    }

    public var body: some View {
        Box(direction: axis.flexDirection, alignItems: .stretch, spacing: spacing) {
            first.flex(clampedFraction, shrink: 1, basis: 0)
            Divider(color: dividerColor,
                    thickness: dividerThickness,
                    axis: axis.dividerAxis)
            second.flex(1 - clampedFraction, shrink: 1, basis: 0)
        }
    }

    private var clampedFraction: Float {
        max(0.05, min(0.95, fraction))
    }
}

private extension SplitView.Axis {
    var flexDirection: FlexDirection {
        switch self {
        case .horizontal:
            return .row
        case .vertical:
            return .column
        }
    }

    var dividerAxis: Divider.Axis {
        switch self {
        case .horizontal:
            return .vertical
        case .vertical:
            return .horizontal
        }
    }
}