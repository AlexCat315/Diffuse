import GuavaUIRuntime

/// Zero-chrome button style. Returns the label exactly as given without any
/// padding, background, or focus ring. Useful for tappable affordances that
/// must blend into custom container chrome (tree disclosures, list rows that
/// own their own selection fill, icon-only toolbar buttons drawn as glyphs).
public struct PlainButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        AnyView(configuration.label)
    }
}

public extension ButtonStyle where Self == PlainButtonStyle {
    static var plain: PlainButtonStyle { PlainButtonStyle() }
}
