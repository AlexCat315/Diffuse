import Foundation
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import PlatformShell

public enum AppDisplayHandleHolder {
    nonisolated(unsafe) public static var current: AppDisplayHandle?
}

public enum AppWindowChromeContextHolder {
    nonisolated(unsafe) public static var current: AppWindowChromeContext?
}

public struct AppWindowChromeContext: Sendable {
    public var windowID: WindowID

    public init(windowID: WindowID) {
        self.windowID = windowID
    }
}

public struct ImmersiveWindowTitleBar<Leading: View>: View {
    public let height: Float
    public let resizeBorderWidth: Float
    public let leading: Leading

    public init(height: Float = 34,
                resizeBorderWidth: Float = 6,
                @ViewBuilder leading: () -> Leading) {
        self.height = height
        self.resizeBorderWidth = resizeBorderWidth
        self.leading = leading()
    }

    public var body: some View {
        _WindowChromeHitTestInstaller(
            hitTest: WindowChromeHitTest(
                titleBarHeight: height,
                resizeBorderWidth: resizeBorderWidth
            )
        )

        Row(alignment: .center, spacing: 0) {
            leading
            WindowDragRegion()
                .frame(height: height)
            WindowControlStrip()
        }
        .padding(horizontal: 6, vertical: 3)
        .frame(height: height)
        .background(.surface)
        .zIndex(20_000)
        .layoutRole("app-window-title-bar")
        .debugName("app-window-title-bar")
    }
}

public struct WindowDragRegion: _PrimitiveView {
    public let minLength: Float

    public init(minLength: Float = 0) {
        self.minLength = minLength
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    public func _updateNode(_ node: Node) {
        node.attachments[WindowChromeAttachmentKey.dragRegion] = true
    }

    public func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.flexGrow = 1
        if minLength > 0 {
            layout.setFlexBasis(minLength)
        }
    }
}

private struct WindowControlStrip: View {
    var body: some View {
        let windowID = AppWindowChromeContextHolder.current?.windowID
        Row(alignment: .center, spacing: 2) {
            WindowControlButton(icon: WindowChromeIcons.minimize, tooltip: "Minimize") {
                withAppDisplayHandle { handle in
                    if let windowID {
                        handle.minimizeWindow(windowID)
                    } else {
                        handle.minimizeWindow()
                    }
                }
            }
            WindowControlButton(icon: WindowChromeIcons.maximize, tooltip: "Maximize") {
                withAppDisplayHandle { handle in
                    if let windowID {
                        handle.toggleMaximizeWindow(windowID)
                    } else {
                        handle.toggleMaximizeWindow()
                    }
                }
            }
            WindowControlButton(icon: WindowChromeIcons.close, tooltip: "Close", isClose: true) {
                withAppDisplayHandle { handle in
                    if let windowID {
                        handle.closeWindow(windowID)
                    } else {
                        handle.closeMainWindow()
                    }
                }
            }
        }
    }
}

private struct WindowControlButton: View {
    let icon: BundleImageResource
    let tooltip: String
    var isClose: Bool = false
    let action: () -> Void

    var body: some View {
        Button(icon: .resource(icon),
               size: 12,
               role: isClose ? .destructive : .normal,
               tooltip: tooltip,
               tint: .white,
               action: action)
            .buttonStyle(.ghost)
            .frame(width: 32, height: 24)
    }
}

private enum WindowChromeIcons {
    static let minimize = BundleImageResource.svg(named: "minimize",
                                                  in: .module,
                                                  subdirectory: "WindowChromeIcons")
    static let maximize = BundleImageResource.svg(named: "maximize",
                                                  in: .module,
                                                  subdirectory: "WindowChromeIcons")
    static let close = BundleImageResource.svg(named: "close",
                                               in: .module,
                                               subdirectory: "WindowChromeIcons")
}

private func withAppDisplayHandle(_ body: @MainActor (AppDisplayHandle) -> Void) {
    MainActor.assumeIsolated {
        guard let handle = AppDisplayHandleHolder.current else { return }
        body(handle)
    }
}

private struct _WindowChromeHitTestInstaller: _PrimitiveView {
    let hitTest: WindowChromeHitTest

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments[WindowChromeAttachmentKey.configuration] = hitTest
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 0
        layout.height = 0
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.width = 0
        layout.height = 0
    }
}

enum WindowChromeAttachmentKey {
    static let configuration = "GuavaUIApp.windowChrome.configuration"
    static let dragRegion = "GuavaUIApp.windowChrome.dragRegion"
}
