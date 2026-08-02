@testable import EditorApp
import SceneRuntime
import Testing

@Suite("Particle module stack editor")
struct ParticleModuleStackEditorTests {
    @Test("layout reserves visible space for every module and expanded diagnostics")
    func layoutTracksVisibleRows() throws {
        var stack = ParticleModuleStack(emitter: ParticleEmitter())
        let collapsedHeight = ParticleModuleStackEditorLayout.rowHeight(stack: stack)

        #expect(collapsedHeight > 300)
        stack.modules[0].isExpanded = true
        let expandedHeight = ParticleModuleStackEditorLayout.rowHeight(stack: stack)
        #expect(expandedHeight == collapsedHeight + ParticleModuleStackEditorLayout.detailRowHeight
            + ParticleModuleStackEditorLayout.rowGap)
    }
}
