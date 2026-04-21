import GuavaUIRuntime

/// Divider default: 1-px line drawn with the `divider` color slot. Spans 100 %
/// of the cross-axis. Returning the legacy `Divider` primitive directly keeps
/// the layout behaviour (`width: 100%` for horizontal, `height: 100%` for
/// vertical) unchanged.
public struct DefaultDividerStyle: DividerStyle {
    public init() {}

    public func makeBody(configuration: DividerStyleConfiguration) -> some View {
        let axis: Divider.Axis = (configuration.orientation == .horizontal)
            ? .horizontal : .vertical
        return Divider(color: configuration.theme.colors.divider,
                       thickness: configuration.thickness,
                       axis: axis)
    }
}
