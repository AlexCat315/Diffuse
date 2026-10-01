import Dispatch
import Foundation
import SceneRuntime
import Testing
@testable import ScriptRuntime

@Suite("Script C bridge context")
struct ScriptCBridgeContextTests {
    @Test("independent scenes keep their bridge contexts on their own threads")
    func concurrentScenes() {
        let ready = DispatchGroup()
        ready.enter()
        ready.enter()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let deltaTime = index == 0 ? 0.125 : 0.75
            let scripts = ScriptRuntime()
            let handle = scripts.register(Script().onUpdate { context in
                ready.leave()
                guard ready.wait(timeout: .now() + 5) == .success else {
                    Issue.record("The other scene did not reach its callback")
                    return
                }
                #expect(guavaDeltaTime() == Float(context.deltaTime))
                #expect(_guavaCurrentScriptContext === context)
            })
            var scene = SceneRuntime()
            scene.setScriptDriver(scripts)
            let entity = scene.createEntity()
            _ = scene.setComponent(ScriptComponent(handle), for: entity)
            _ = scene.tick(deltaTime: deltaTime)
            #expect(_guavaCurrentScriptContext == nil)
        }
    }

    @Test("nested scene callbacks restore the outer bridge context")
    func nestedCallbacks() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(Script().onUpdate { outer in
            let innerScripts = ScriptRuntime()
            let innerHandle = innerScripts.register(Script().onUpdate { _ in
                #expect(guavaDeltaTime() == 0.5)
            })
            var inner = SceneRuntime()
            inner.setScriptDriver(innerScripts)
            let innerEntity = inner.createEntity()
            _ = inner.setComponent(ScriptComponent(innerHandle), for: innerEntity)
            _ = inner.tick(deltaTime: 0.5)
            #expect(_guavaCurrentScriptContext === outer)
            #expect(guavaDeltaTime() == 0.25)
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let entity = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(handle), for: entity)
        _ = scene.tick(deltaTime: 0.25)
        #expect(_guavaCurrentScriptContext == nil)
    }

    @Test("removed bindings receive a C bridge context in onDestroy")
    func destroyCallback() {
        let scripts = ScriptRuntime()
        let destroyed = ScriptVar(false)
        let handle = scripts.register(Script().onDestroy { context in
            destroyed.value = true
            #expect(_guavaCurrentScriptContext === context)
            #expect(guavaDeltaTime() == 0.25)
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let entity = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(handle), for: entity)
        _ = scene.tick(deltaTime: 0.1)
        _ = scene.removeComponent(ScriptComponent.self, from: entity)
        _ = scene.tick(deltaTime: 0.25)
        #expect(destroyed.value)
        #expect(_guavaCurrentScriptContext == nil)
    }
}
