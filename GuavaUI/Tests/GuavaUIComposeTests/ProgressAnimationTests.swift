import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Progress presentation")
struct ProgressAnimationTests {
    @Test("Both progress controls interpolate values")
    func valuesAnimate() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            for circular in [false, true] {
                let initial: any _PrimitiveView = circular ? ProgressCircle(value: 0.2) : ProgressView(value: 0.2)
                let updated: any _PrimitiveView = circular ? ProgressCircle(value: 0.8) : ProgressView(value: 0.8)
                let node = initial._makeNode()
                initial._updateNode(node)
                let presentation = node.firstResource(ProgressValue.self)!
                #expect(presentation.value == 0.2)
                updated._updateNode(node)
                #expect(presentation.value == 0.2)
                let tree = NodeTree()
                tree.root = node
                tree.flush()
                scheduler.tick(deltaTime: 0.04)
                #expect(!node.isDirty && node.renderDirty)
                #expect(presentation.value > 0.2 && presentation.value < 0.8)
                scheduler.tick(deltaTime: 1)
                #expect(presentation.value == 0.8)
            }
            #expect(!scheduler.hasActiveAnimations)
        }
    } }

    @Test("Explicitly disabled animation and mode changes snap")
    func snaps() { GlobalTestLock.locked {
        let node = ProgressView(value: 0.2)._makeNode()
        ProgressView(value: 0.2)._updateNode(node)
        ActiveAnimationContext.with(nil) { ProgressView(value: 0.9)._updateNode(node) }
        let presentation = node.firstResource(ProgressValue.self)!
        #expect(presentation.value == 0.9)
        ProgressView(value: nil)._updateNode(node)
        ProgressView(value: 0.4)._updateNode(node)
        #expect(presentation.value == 0.4)
        node.setCompositionValue(ReducedMotionEnvironment.key, true)
        ProgressView(value: 0.7)._updateNode(node)
        #expect(presentation.value == 0.7)
    } }
}
