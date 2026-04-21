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

/// Process-wide clipboard bridge. The host installs read/write closures
/// (typically wired to `SDL_GetClipboardText` / `SDL_SetClipboardText`);
/// primitives such as `TextField` invoke them for copy / cut / paste.
///
/// Both closures are optional — if absent, the corresponding command is a
/// no-op rather than a crash, which keeps tests headless without a clipboard.
public enum ClipboardHolder {
    nonisolated(unsafe) public static var read: (() -> String?)?
    nonisolated(unsafe) public static var write: ((String) -> Void)?
}

/// Process-wide pointer-capture holder. Primitives that need to track the
/// pointer outside their own bounds during a drag (e.g. `TextField` text
/// selection) call `current?.acquire(node)` on pointer-down and
/// `current?.release()` on pointer-up.
public enum PointerCaptureHolder {
    nonisolated(unsafe) public static var current: PointerCapture?
}
