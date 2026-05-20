import Foundation
import GuavaUICompose
import GuavaUIRuntime
import PlatformShell

public enum AppDisplayHandleHolder {
    nonisolated(unsafe) public static var current: AppDisplayHandle?
}

public struct ImmersiveWindowTitleBar<Leading: View>: View {
    public let height: Float
    public let draggableLeadingInset: Float
    public let draggableTrailingInset: Float
    public let resizeBorderWidth: Float
    public let leading: Leading

    public init(height: Float = 34,
                draggableLeadingInset: Float = 0,
                draggableTrailingInset: Float = 112,
                resizeBorderWidth: Float = 6,
                @ViewBuilder leading: () -> Leading) {
        self.height = height
        self.draggableLeadingInset = draggableLeadingInset
        self.draggableTrailingInset = draggableTrailingInset
        self.resizeBorderWidth = resizeBorderWidth
        self.leading = leading()
    }

    public var body: some View {
        _WindowChromeHitTestInstaller(
            hitTest: WindowChromeHitTest(
                titleBarHeight: height,
                draggableLeadingInset: draggableLeadingInset,
                draggableTrailingInset: draggableTrailingInset,
                resizeBorderWidth: resizeBorderWidth
            )
        )

        Row(alignment: .center, spacing: 0) {
            leading
            Spacer()
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

private struct WindowControlStrip: View {
    var body: some View {
        Row(alignment: .center, spacing: 2) {
            WindowControlButton(icon: WindowChromeIcons.minimize, tooltip: "Minimize") {
                withAppDisplayHandle { handle in
                    handle.minimizeWindow()
                }
            }
            WindowControlButton(icon: WindowChromeIcons.maximize, tooltip: "Maximize") {
                withAppDisplayHandle { handle in
                    handle.toggleMaximizeWindow()
                }
            }
            WindowControlButton(icon: WindowChromeIcons.close, tooltip: "Close", isClose: true) {
                withAppDisplayHandle { handle in
                    handle.closeMainWindow()
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
        withAppDisplayHandle { handle in
            handle.setWindowChromeHitTest(hitTest)
        }
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
