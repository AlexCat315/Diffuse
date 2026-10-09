import GuavaUIRuntime

/// Shared desktop control density. Explicit per-control sizes take precedence;
/// otherwise the nearest `.controlSize` provider sizes a whole toolbar or form.
public enum ControlSize: Sendable, Hashable, CaseIterable {
    case mini, small, regular, large

    public var buttonHeight: Float {
        switch self {
        case .mini: 20
        case .small: 24
        case .regular: 28
        case .large: 36
        }
    }

    public var horizontalPadding: Float {
        switch self {
        case .mini: 5
        case .small: 7
        case .regular: 8
        case .large: 12
        }
    }

    var textFieldSize: TextField.Size {
        switch self {
        case .mini, .small: .small
        case .regular: .regular
        case .large: .large
        }
    }
}

public enum ControlSizeEnvironment {
    public static let key = CompositionLocal<ControlSize>(defaultValue: .regular)
}

public extension View {
    func controlSize(_ size: ControlSize) -> some View {
        compositionLocal(ControlSizeEnvironment.key, size)
    }
}
