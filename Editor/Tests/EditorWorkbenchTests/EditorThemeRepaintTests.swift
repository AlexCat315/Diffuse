import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing
@testable import EditorCore
@testable import EditorUI

/// The theme boundary used to key its subtree on a revision that every theme
/// change bumped, so switching themes remounted the whole window and re-ran
/// Yoga. That is the flash. These tests pin the cheaper contract: the tokens
/// reach the nodes through `ThemeEnvironment`, the nodes themselves survive.
@Suite("Editor theme repaint", .serialized)
struct EditorThemeRepaintTests {
    private final class Harness: View {
        @State private var presentation = EditorPresentationState(themeMode: .dark)
        var body: some View {
            EditorPresentationBoundary(presentation: presentation) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    Box {}.debugName("probe").background(.background).frame(height: 24)
                    Text("hello").debugName("caption")
                }
                .frame(width: 320, height: 200)
            }
        }
        func useLightTheme() { presentation.setThemeMode(.light) }
    }

    @Test("Switching the theme repaints the existing nodes and leaves layout alone")
    func themeSwitchRepaintsInPlace() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        let harness = Harness()
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        func settle() {
            for _ in 0..<3 { graph.recomposer.commitAll() }
            graph.computeLayout(width: 640, height: 480)
        }
        settle()

        let darkProbe = try WorkbenchUITestSupport.named("probe", in: graph.tree.root)
        let darkBackground = try #require(darkProbe.backgroundColor)
        #expect(darkBackground == EditorVisualTheme.make(dark: true).colors.background)
        let identity = ObjectIdentifier(darkProbe)
        let layoutIdentity = try #require(darkProbe.layoutNode)

        harness.useLightTheme()
        settle()

        // Same node: nothing was torn down and re-materialised.
        let lightProbe = try WorkbenchUITestSupport.named("probe", in: graph.tree.root)
        #expect(ObjectIdentifier(lightProbe) == identity)
        #expect(lightProbe.layoutNode === layoutIdentity)
        #expect(try #require(lightProbe.backgroundColor)
                == EditorVisualTheme.make(dark: false).colors.background)
        #expect(lightProbe.backgroundColor != darkBackground)

        // Nothing about a palette swap moves a box, so the next frame must not
        // have to re-measure the window.
        #expect(!graph.layoutNeedsUpdate(width: 640, height: 480))
    } }

    @Test("A refresh revision is the only thing that rebuilds the boundary")
    func refreshRevisionRebuilds() throws { try WorkbenchUITestSupport.withEnvironment { _, _ in
        var presentation = EditorPresentationState(themeMode: .dark)
        let switched = presentation.setThemeMode(.light)
        #expect(switched)
        #expect(presentation.refreshRevision == 0)
        // Re-selecting the current mode is a no-op, so a double click cannot
        // queue two reveals or two rebuilds.
        let repeated = presentation.setThemeMode(.light)
        #expect(!repeated)
        #expect(presentation.refreshRevision == 0)

        presentation.forceRefresh()
        #expect(presentation.refreshRevision == 1)
        #expect(presentation.themeMode == .light)
    } }
}