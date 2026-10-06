import Foundation
import SceneRuntime
import SIMDCompat
import Testing
@testable import ScriptRuntime

@Suite("Script authoring contract")
struct ScriptDefinitionTests {
    private let definition = ScriptDefinition(properties: [
        ScriptProperty("speed", defaultValue: .number(2), minimum: 0, maximum: 10),
        ScriptProperty("lives", defaultValue: .integer(3), minimum: 1),
        ScriptProperty("enabled", defaultValue: .boolean(true)),
        ScriptProperty("axis", defaultValue: .vector3(SIMD3(0, 1, 0))),
        ScriptProperty("mode", defaultValue: .string("ready"), options: [ScriptPropertyOption("ready"), ScriptPropertyOption("playing")]),
    ])

    @Test("metadata roundtrips and validates typed properties rather than JSON syntax alone")
    func typedValidation() throws {
        let restored = try JSONDecoder().decode(ScriptDefinition.self, from: JSONEncoder().encode(definition))
        #expect(restored == definition)
        #expect(definition.parameterIssues(in: #"{"speed":4,"lives":5,"enabled":false,"axis":[1,2,3],"mode":"playing"}"#).isEmpty)
        #expect(definition.parameterIssues(in: #"{"speed":true,"lives":2.5,"enabled":1,"axis":[1,true,3],"mode":"other","title":"ignored"}"#).count == 6)
        #expect(!definition.parameterIssues(in: "[]").isEmpty)
        #expect(!definition.parameterIssues(in: #"{"speed":20}"#).isEmpty)
    }

    @Test("definition defaults, project defaults and instance overrides have one precedence order")
    func resolvesDefaults() {
        let values = definition.resolvedParameters(defaultsJSON: #"{"speed":4}"#, overridesJSON: #"{"lives":5,"mode":"playing"}"#)
        #expect(values["speed"] as? Double == 4)
        #expect(values["lives"] as? Int == 5)
        #expect(values["enabled"] as? Bool == true)
        #expect(values["mode"] as? String == "playing")
        let invalid = definition.resolvedParameters(defaultsJSON: #"{"speed":4}"#, overridesJSON: #"{"speed":true,"lives":0,"mode":"other"}"#)
        #expect(invalid["speed"] as? Double == 4)
        #expect(invalid["lives"] as? Int == 3)
        #expect(invalid["mode"] as? String == "ready")
    }

    private struct AuthoredBehavior: ScriptBehavior, ScriptAuthoring {
        static var definition: ScriptDefinition {
            ScriptDefinition(properties: [ScriptProperty("speed", defaultValue: .number(6))])
        }
        mutating func onUpdate(_ context: ScriptContext) {
            context.translate(by: SIMD3(context.floatParameter("speed") ?? -1, 0, 0))
        }
    }

    @Test("native behavior registration carries its optional authoring contract")
    func nativeBehavior() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(behavior: AuthoredBehavior.self)
        let binding = ScriptBinding(handle)
        #expect(scripts.definition(for: binding)?.properties.first?.key == "speed")
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let entity = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(binding), for: entity)
        _ = scene.tick(deltaTime: 0.1)
        #expect(scene.localTransform(for: entity)?.translation.x == 6)
    }

    private final class DestroyLog: @unchecked Sendable { var values: [Double] = [] }

    @Test("destruction retains the previous generation's defaults after reload or binding removal")
    func destructionDefaults() {
        let scripts = ScriptRuntime()
        let log = DestroyLog()
        func register(defaultValue: Double) -> ScriptHandle {
            scripts.register(named: "test.reload", definition: ScriptDefinition(properties: [
                ScriptProperty("speed", defaultValue: .number(defaultValue))
            ])) {
                Script(onDestroy: { context in log.values.append(context.doubleParameter("speed") ?? -1) })
            }
        }
        let handle = register(defaultValue: 2)
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let entity = scene.createEntity()
        let binding = ScriptBinding(handle)
        _ = scene.setComponent(ScriptComponent(binding), for: entity)
        _ = scene.tick(deltaTime: 0.1)
        _ = register(defaultValue: 8)
        #expect(scripts.needsReload(binding, on: entity))
        _ = scene.tick(deltaTime: 0.1)
        #expect(log.values == [2])
        _ = scene.removeComponent(ScriptComponent.self, from: entity)
        _ = scene.tick(deltaTime: 0.1)
        #expect(log.values == [2, 8])
    }

    @Test("the runtime applies the same defaults and keeps each binding's overrides isolated")
    func runtimeDefaults() throws {
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "test.contract", defaultParametersJSON: #"{"speed":4}"#, definition: definition) {
            Script(onTick: { context in
                context.translate(by: SIMD3(context.floatParameter("speed") ?? -1, 0, 0))
            })
        }
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let first = scene.createEntity()
        let second = scene.createEntity()
        let firstBinding = ScriptBinding(handle)
        let secondBinding = ScriptBinding(handle, parametersJSON: #"{"speed":7}"#)
        _ = scene.setComponent(ScriptComponent(firstBinding), for: first)
        _ = scene.setComponent(ScriptComponent(secondBinding), for: second)
        #expect(scripts.definition(for: firstBinding) == definition)
        #expect(!scripts.isActive(firstBinding, on: first))
        _ = scene.tick(deltaTime: 0.1)
        #expect(scene.localTransform(for: first)?.translation.x == 4)
        #expect(scene.localTransform(for: second)?.translation.x == 7)
        #expect(scripts.isActive(firstBinding, on: first))
        scripts.stop(in: &scene)
        #expect(!scripts.isActive(firstBinding, on: first))
    }
}
