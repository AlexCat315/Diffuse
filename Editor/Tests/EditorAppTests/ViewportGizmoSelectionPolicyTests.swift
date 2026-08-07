@testable import EditorApp
import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@Suite("Viewport gizmo selection policy")
struct ViewportGizmoSelectionPolicyTests {
    @Test("primary is first and selected descendants are excluded")
    func editableRootsAreDeterministic() {
        let ancestorIDs: Set<UInt64> = [3]

        let result = EditorGizmoSelectionPolicy.editableRootEntityIDs(
            primary: 2,
            editableSelection: [1, 2, 3],
            hasSelectedAncestor: { ancestorIDs.contains($0) }
        )

        #expect(result == [2, 1])
    }

    @Test("a non-editable primary cannot start a group transform")
    func missingPrimaryRejectsTransform() {
        #expect(EditorGizmoSelectionPolicy.editableRootEntityIDs(
            primary: 9,
            editableSelection: [1, 2],
            hasSelectedAncestor: { _ in false }
        ).isEmpty)
    }

    @Test("a locked member rejects the complete group transform")
    func lockedMemberRejectsAtomicTransform() {
        #expect(EditorGizmoSelectionPolicy.permitsAtomicTransform(
            primary: 1,
            selectedEntityIDs: [1, 2, 3],
            isLocked: { $0 == 2 }
        ) == false)
        #expect(EditorGizmoSelectionPolicy.permitsAtomicTransform(
            primary: 1,
            selectedEntityIDs: [1, 2, 3],
            isLocked: { _ in false }
        ))
    }
}

@Suite("Viewport key routing policy")
struct ViewportKeyRoutingPolicyTests {
    private func key(_ scancode: UInt32, _ modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)
    }

    @Test("raw tool keys remain local")
    func rawKeysRemainLocal() {
        #expect(EditorViewportKeyRoutingPolicy.handlesLocally(key(Scancode.r, [])))
        #expect(EditorViewportKeyRoutingPolicy.handlesLocally(key(Scancode.b, [.lshift])))
    }

    @Test("application chords bypass viewport side effects")
    func commandChordsBypassViewport() {
        #expect(!EditorViewportKeyRoutingPolicy.handlesLocally(key(Scancode.d, [.lgui])))
        #expect(!EditorViewportKeyRoutingPolicy.handlesLocally(key(Scancode.b, [.rctrl])))
        #expect(!EditorViewportKeyRoutingPolicy.handlesLocally(key(Scancode.r, [.lgui, .lshift])))
    }

    @Test("editing commands use layout-independent scancodes")
    func editingCommandsUseScancodes() {
        #expect(EditorViewportEditingShortcutPolicy.command(
            for: key(ComposeScancode.f, [])
        ) == .frameSelection)
        #expect(EditorViewportEditingShortcutPolicy.command(
            for: key(ComposeScancode.backspace, [])
        ) == .deleteSelection)
        #expect(EditorViewportEditingShortcutPolicy.command(
            for: key(ComposeScancode.delete, [])
        ) == .deleteSelection)
        #expect(EditorViewportEditingShortcutPolicy.command(
            for: key(ComposeScancode.f, [.lgui])
        ) == nil)
    }

    @Test("tool shortcuts include persistent box selection and bypass command chords")
    func toolShortcutsUseScancodes() {
        #expect(EditorViewportToolShortcutPolicy.mode(
            for: key(ComposeScancode.q, [])
        ) == EditorGizmoMode.none)
        #expect(EditorViewportToolShortcutPolicy.mode(
            for: key(ComposeScancode.b, [])
        ) == .boxSelect)
        #expect(EditorViewportToolShortcutPolicy.mode(
            for: key(ComposeScancode.w, [])
        ) == .translate)
        #expect(EditorViewportToolShortcutPolicy.mode(
            for: key(ComposeScancode.e, [])
        ) == .rotate)
        #expect(EditorViewportToolShortcutPolicy.mode(
            for: key(ComposeScancode.r, [])
        ) == .scale)
        #expect(EditorViewportToolShortcutPolicy.mode(
            for: key(ComposeScancode.b, [.lgui])
        ) == nil)
    }

    @Test("box selection mode reduces and persists like other viewport tools")
    func boxSelectionModePersists() throws {
        var state = EditorState()
        EditorReducer.reduce(state: &state, action: .setGizmoMode(.boxSelect))
        #expect(state.gizmoMode == .boxSelect)

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(EditorState.self, from: data)
        #expect(restored.gizmoMode == .boxSelect)
    }
}

@Suite("Viewport chrome layout")
struct ViewportChromeLayoutTests {
    @Test("narrow viewport reserves a non-overlapping view-cube region")
    func narrowToolbarDoesNotOverlapCube() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Box {
                ViewportChromeLayout {
                    Box(direction: .row,
                        alignItems: .center,
                        wrap: .wrap,
                        spacing: 5) {
                        Box { EmptyView() }.frame(width: 230, height: 26)
                        Box { EmptyView() }.frame(width: 210, height: 26)
                        Box { EmptyView() }.frame(width: 170, height: 26)
                    }
                    .debugName("viewport-test-toolbar")
                } cube: {
                    Box { EmptyView() }
                        .debugName("viewport-test-cube")
                }
            }
            .frame(width: 646, height: 300)
        )

        graph.computeLayout(width: 646, height: 300)
        let snapshot = graph.layoutSnapshot()
        let toolbar = snapshot.first { $0.debugName == "viewport-test-toolbar" }?.absoluteFrame
        let cube = snapshot.first { $0.debugName == "viewport-test-cube" }?.absoluteFrame

        #expect(toolbar != nil)
        #expect(cube != nil)
        if let toolbar, let cube {
            #expect(toolbar.maxX <= cube.minX)
            #expect(cube.maxX <= 636)
            #expect(toolbar.height > 26) // the control clusters wrapped instead of overflowing
        }
    }
}
