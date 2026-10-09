import GuavaUIRuntime

public extension View {
    /// Apply asymmetric padding by axis. Equivalent to constructing an
    /// `EdgeInsets` with matching horizontal and vertical pairs.
    func padding(horizontal: Float = 0, vertical: Float = 0) -> some View {
        modifier(PaddingModifier(insets: EdgeInsets(top: vertical,
                                                    leading: horizontal,
                                                    bottom: vertical,
                                                    trailing: horizontal)))
    }
}
