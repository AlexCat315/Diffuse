import XCTest
import EngineKernel
@testable import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime

final class WindowChromeAutoTests: XCTestCase {
    func testWindowTitleBarModifierInjectsIntoCurrentWindowModel() {
        let windowID: WindowID = 4242
        let model = WindowChromeModel()
        WindowChromeModelStore.register(model, for: windowID)
        AppWindowChromeContextHolder.current = AppWindowChromeContext(windowID: windowID)
        defer {
            AppWindowChromeContextHolder.current = nil
            WindowChromeModelStore.unregister(windowID)
        }

        XCTAssertEqual(model.revision, 0)

        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root:
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Text("content")
            }
            .windowTitleBar {
                Text("MENU").debugName("injected-title")
            }
        )
        graph.computeLayout(width: 400, height: 300)

        // The modifier ran during install and pushed its content into the
        // window's model.
        XCTAssertGreaterThan(model.revision, 0)

        // The stored title bar renders the injected content.
        let titleGraph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        titleGraph.install(root: model.titleBar)
        titleGraph.computeLayout(width: 400, height: 34)
        let names = titleGraph.layoutSnapshot().compactMap { $0.debugName }
        XCTAssertTrue(names.contains("injected-title"),
                      "title bar should render the injected content; got \(names)")
    }

    func testWindowTitleBarIsNoOpWithoutARegisteredWindow() {
        // No model registered / no chrome context → the modifier must not crash
        // and simply drops the content (the native title-bar-style behaviour).
        AppWindowChromeContextHolder.current = nil
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root:
            Text("content").windowTitleBar { Text("MENU") }
        )
        graph.computeLayout(width: 400, height: 300)
        XCTAssertTrue(true)
    }
}
