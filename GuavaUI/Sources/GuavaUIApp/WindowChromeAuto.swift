import Foundation
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import PlatformShell

// MARK: - Public API

public extension View {
    /// Places `content` in this window's immersive title bar, next to the
    /// minimize / maximize / close controls. Vary it per screen — the most
    /// recently rendered screen's bar wins.
    ///
    /// Under the immersive (borderless) window style, `AppRuntime` mounts the
    /// title bar automatically, so you never hand-roll the chrome: just attach
    /// this where you want a menu / title shown. Under the native title-bar
    /// style the OS owns the bar and this is a no-op.
    func windowTitleBar<TitleBar: View>(@ViewBuilder _ content: () -> TitleBar) -> some View {
        modifier(_WindowTitleBarModifier(content: AnyView(content())))
    }
}

// MARK: - Per-window model

/// Carries the title-bar content injected by `.windowTitleBar` for one window.
/// `AppRuntime` creates one per immersive window; `_WindowTitleBarSlot` observes
/// it and the screen's `.windowTitleBar` modifier writes to it.
public final class WindowChromeModel: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<WindowChromeModel>()
    /// Bumped on every change so an `Observed(\.revision)` dependency refreshes
    /// (the content itself is an `AnyView` and therefore not `Equatable`).
    public private(set) var revision: Int = 0
    public private(set) var titleBar: AnyView = AnyView(EmptyView())

    public init() {}

    func setTitleBar(_ view: AnyView) {
        titleBar = view
        revision &+= 1
        publisher.send()
    }

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        publisher.register(on: self, handler: handler)
    }

    public func _unregisterObserver(_ token: AnyHashable) {
        publisher.unregister(token)
    }
}

/// Maps each immersive window to its title-bar model. The `.windowTitleBar`
/// modifier resolves the current window from `AppWindowChromeContextHolder`
/// (set around composition) and writes into the matching model.
enum WindowChromeModelStore {
    nonisolated(unsafe) private static var models: [WindowID: WindowChromeModel] = [:]
    private static let lock = NSLock()

    static func register(_ model: WindowChromeModel, for id: WindowID) {
        lock.lock(); defer { lock.unlock() }
        models[id] = model
    }

    static func model(for id: WindowID) -> WindowChromeModel? {
        lock.lock(); defer { lock.unlock() }
        return models[id]
    }

    static func unregister(_ id: WindowID) {
        lock.lock(); defer { lock.unlock() }
        models.removeValue(forKey: id)
    }
}

// MARK: - Auto chrome (mounted by AppRuntime for immersive windows)

private struct _WindowTitleBarModifier: ViewModifier {
    let content: AnyView

    func apply(node: Node) {
        guard let windowID = AppWindowChromeContextHolder.current?.windowID,
              let model = WindowChromeModelStore.model(for: windowID) else { return }
        model.setTitleBar(content)
    }
}

private struct _WindowTitleBarSlot: View {
    private let model: WindowChromeModel
    private var revision: Observed<WindowChromeModel, Int>

    init(model: WindowChromeModel) {
        self.model = model
        self.revision = Observed(\.revision, on: model)
    }

    var body: some View {
        // Touch the revision so this slot recomposes when the injected title-bar
        // content changes; then render whatever the screen most recently set.
        let _ = revision.wrappedValue
        model.titleBar
    }
}

/// The implicit root wrapper for an immersive window: the platform title bar
/// (drag region + window controls) over the app's content, with the title-bar
/// leading slot fed by `.windowTitleBar`.
struct _AutoWindowChrome<Content: View>: View {
    let model: WindowChromeModel
    let content: Content

    init(model: WindowChromeModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        WindowScaffold(titleBar: { _WindowTitleBarSlot(model: model) }) {
            content
        }
    }
}

/// Installs `rootView` into `graph`, transparently wrapping it in the immersive
/// chrome when the window uses the borderless style — so apps get a working,
/// closable title bar for free and never hand-roll it.
@MainActor
func installAppRoot<Root: View>(_ rootView: Root,
                                windowID: WindowID?,
                                titleBarStyle: AppWindowTitleBarStyle,
                                into graph: ViewGraph) {
    guard titleBarStyle == .hiddenInset, let windowID else {
        graph.install(root: rootView)
        return
    }
    let model = WindowChromeModel()
    WindowChromeModelStore.register(model, for: windowID)
    graph.install(root: _AutoWindowChrome(model: model) { rootView })
}
