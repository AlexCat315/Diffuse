import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("TriggerDetection")
struct TriggerDetectionTests {

    @Test("enter event fires when entity overlaps trigger")
    func enterFiresOnOverlap() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()

        // Trigger entity with a large box
        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: trigger)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(2, 2, 2), center: .zero),
                     isTrigger: true,
                     layerID: 1,
                     layerMask: .max),
            for: trigger
        )

        // Other entity outside at first
        let other = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0, 10)), for: other)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     isTrigger: false,
                     layerID: 2,
                     layerMask: .max),
            for: other
        )

        // First tick: other is far away — no trigger
        _ = runtime.tick(deltaTime: 0.1)
        let frame1 = runtime.resource(TriggerFrameResource.self)
        #expect(frame1 != nil)
        #expect(frame1!.enters.isEmpty)

        // Move other inside trigger's bounds
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0, 1)), for: other)
        _ = runtime.tick(deltaTime: 0.1)

        let frame2 = runtime.resource(TriggerFrameResource.self)
        #expect(frame2 != nil)
        #expect(frame2!.enters.count == 1)
        #expect(frame2!.enters[0].triggerEntity == trigger)
        #expect(frame2!.enters[0].otherEntity == other)
    }

    @Test("exit event fires when entity leaves trigger")
    func exitFiresOnLeave() {
        var runtime = SceneRuntime()

        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: trigger)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(2, 2, 2), center: .zero),
                     isTrigger: true, layerID: 1, layerMask: .max),
            for: trigger
        )

        let other = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: other)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     isTrigger: false, layerID: 2, layerMask: .max),
            for: other
        )

        // First tick: overlapping — enter fires
        _ = runtime.tick(deltaTime: 0.1)
        let frame1 = runtime.resource(TriggerFrameResource.self)
        #expect(frame1!.enters.count == 1)

        // Move other far away
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0, 10)), for: other)
        _ = runtime.tick(deltaTime: 0.1)

        let frame2 = runtime.resource(TriggerFrameResource.self)
        #expect(frame2!.exits.count == 1)
        #expect(frame2!.exits[0].triggerEntity == trigger)
        #expect(frame2!.exits[0].otherEntity == other)
        #expect(frame2!.enters.isEmpty)
    }

    @Test("layer mask filters out non-matching overlaps")
    func layerMaskFiltersOverlaps() {
        var runtime = SceneRuntime()

        // Trigger only detects layer 1
        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: trigger)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(2, 2, 2), center: .zero),
                     isTrigger: true, layerID: 0, layerMask: 0b0010),
            for: trigger
        )

        // Other entity on layer 2 (bit 2) but trigger mask only has bit 1
        let other = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: other)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     isTrigger: false, layerID: 2, layerMask: .max),
            for: other
        )

        _ = runtime.tick(deltaTime: 0.1)

        let frame = runtime.resource(TriggerFrameResource.self)
        #expect(frame != nil)
        // Should NOT trigger: trigger mask bit 1 (0b0010) doesn't match other layer 2 (0b0100)
        #expect(frame!.enters.isEmpty)
    }

    @Test("trigger stays active while overlapping across frames")
    func triggerStaysActiveWhileOverlapping() {
        var runtime = SceneRuntime()

        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: trigger)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(2, 2, 2), center: .zero),
                     isTrigger: true, layerID: 1, layerMask: .max),
            for: trigger
        )

        let other = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: other)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     isTrigger: false, layerID: 2, layerMask: .max),
            for: other
        )

        _ = runtime.tick(deltaTime: 0.1)
        // Second frame: still overlapping, no new enter events
        _ = runtime.tick(deltaTime: 0.1)

        let frame2 = runtime.resource(TriggerFrameResource.self)
        #expect(frame2!.enters.isEmpty)   // no NEW enters
        #expect(frame2!.exits.isEmpty)    // no exits either
        #expect(frame2!.active.count == 1) // still active
    }

    @Test("multiple triggers detect independently")
    func multipleTriggersDetectIndependently() {
        var runtime = SceneRuntime()

        let triggerA = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(-3, 0, 0)), for: triggerA)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 1, 1), center: .zero),
                     isTrigger: true, layerID: 1, layerMask: .max),
            for: triggerA
        )

        let triggerB = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(3, 0, 0)), for: triggerB)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 1, 1), center: .zero),
                     isTrigger: true, layerID: 1, layerMask: .max),
            for: triggerB
        )

        let other = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(-3, 0, 0)), for: other)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     isTrigger: false, layerID: 2, layerMask: .max),
            for: other
        )

        _ = runtime.tick(deltaTime: 0.1)

        let frame = runtime.resource(TriggerFrameResource.self)
        #expect(frame!.enters.count == 1)
        #expect(frame!.enters[0].triggerEntity == triggerA)
        #expect(frame!.enters[0].otherEntity == other)
    }
}
