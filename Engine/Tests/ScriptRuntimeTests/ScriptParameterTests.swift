import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("ScriptParameters")
struct ScriptParameterTests {

    @Test("parametersJSON is passed to onStart handler")
    func parametersPassedToOnStart() {
        let capture = ScriptVar<String>("")
        let scripts = ScriptRuntime()
        let script = scripts.register(
            Script().onStart { ctx in
                capture.value = ctx.parametersJSON
            }
        )

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(script, parametersJSON: #"{"speed": 2.5}"#)),
            for: entity
        )

        _ = runtime.tick(deltaTime: 0.1)
        #expect(capture.value == #"{"speed": 2.5}"#)
    }

    @Test("parametersJSON is passed to onTick handler")
    func parametersPassedToOnTick() {
        let capture = ScriptVar<String>("")
        let scripts = ScriptRuntime()
        let script = scripts.register(
            Script().onTick { ctx in
                capture.value = ctx.parametersJSON
            }
        )

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(script, parametersJSON: #"{"speed": 2.5}"#)),
            for: entity
        )

        _ = runtime.tick(deltaTime: 0.1)
        #expect(capture.value == #"{"speed": 2.5}"#)
    }

    @Test("parameters decodes JSON into dictionary on access")
    func parametersDecodesJSON() {
        let speed = ScriptVar<Double>(0)
        let scripts = ScriptRuntime()
        let script = scripts.register(
            Script().onTick { ctx in
                speed.value = ctx.parameters["speed"] as? Double ?? 0
            }
        )

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(script, parametersJSON: #"{"speed": 3.14}"#)),
            for: entity
        )

        _ = runtime.tick(deltaTime: 0.1)
        #expect(speed.value == 3.14)
    }

    @Test("parameters caches decoded dictionary")
    func parametersCachesDecodedValue() {
        let count = ScriptVar<Int>(0)
        let scripts = ScriptRuntime()
        let script = scripts.register(
            Script().onTick { ctx in
                _ = ctx.parameters
                _ = ctx.parameters
                count.value += 1
            }
        )

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(script, parametersJSON: #"{"x": 1}"#)),
            for: entity
        )

        _ = runtime.tick(deltaTime: 0.1)
        #expect(count.value == 1)
    }

    @Test("parameters returns empty dict for default JSON")
    func parametersEmptyForDefaultJSON() {
        let count = ScriptVar<Int>(0)
        let scripts = ScriptRuntime()
        let script = scripts.register(
            Script().onStart { ctx in
                if ctx.parameters.isEmpty { count.value += 1 }
            }
        )

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(ScriptComponent(script), for: entity)

        _ = runtime.tick(deltaTime: 0.1)
        #expect(count.value == 1)
    }
}
