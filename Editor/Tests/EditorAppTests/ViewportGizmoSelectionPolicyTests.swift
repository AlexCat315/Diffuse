@testable import EditorApp
import EngineKernel
import GuavaUICompose
import Testing

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
}
