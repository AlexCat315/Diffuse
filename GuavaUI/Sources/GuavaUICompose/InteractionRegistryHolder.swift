import GuavaUIRuntime

/// Process-wide interaction registry holder. The host installs the active
/// `InteractionRegistry` here once at startup; primitives such as `Button`
/// and `ScrollView` register their handlers through it during materialisation.
///
/// Mirrors the `TextEnvironmentHolder` pattern so primitives stay free of
/// constructor injection.
public enum InteractionRegistryHolder {
    nonisolated(unsafe) public static var current: InteractionRegistry?
}

/// Process-wide focus chain holder. `TextField` (and other focus-aware
/// primitives) read this during draw to decide whether to render a cursor /
/// focus ring.
public enum FocusChainHolder {
    nonisolated(unsafe) public static var current: FocusChain?
}
