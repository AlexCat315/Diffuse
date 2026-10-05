import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func animationPlayerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AnimationPlayer.self, for: entity) else { return nil }

        return EditorInspectorSection(
            id: "animation-player",
            title: L("Animation Player"),
            fields: [
                EditorInspectorField(
                    id: "anim-clip",
                    label: L("Clip"),
                    value: .text(animationClipNameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-speed",
                    label: L("Speed"),
                    value: .constrainedNumber(animationSpeedBinding(for: entity),
                                              min: 0, max: 10, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "anim-loop",
                    label: L("Loop"),
                    value: .bool(animationLoopBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-playing",
                    label: L("Playing"),
                    value: .bool(animationIsPlayingBinding(for: entity))
                ),
            ]
        )
    }

    private func animationClipNameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.clipName ?? ""
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity) else { return }
                let clipName: String? = next.isEmpty ? nil : next
                guard player.clipName != clipName else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_clip",
                                          summary: "Update animation clip",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: clipName,
                                                                          speed: player.speed,
                                                                          loop: player.loop,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationSpeedBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.speed ?? 1
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.speed != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_speed",
                                          summary: "Update animation speed",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: next,
                                                                          loop: player.loop,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationLoopBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.loop ?? true
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.loop != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_loop",
                                          summary: "Update animation loop",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: player.speed,
                                                                          loop: next,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationIsPlayingBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.isPlaying ?? false
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.isPlaying != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_playing",
                                          summary: "Update animation playing state",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: player.speed,
                                                                          loop: player.loop,
                                                                          isPlaying: next)])
            }
        )
    }

    func animationGraphPlayerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let player = scene.component(AnimationGraphPlayer.self, for: entity) else { return nil }
        let stateCount = player.graph.stateMachine.states.count
        let blendSpaceCount = player.graph.blendSpaces1D.count
        let activeState = player.activeState ?? player.graph.stateMachine.initialState
        let previousState = player.previousState ?? L("None")

        return EditorInspectorSection(
            id: "animation-graph-player",
            title: L("Animation Graph"),
            fields: [
                EditorInspectorField(
                    id: "anim-graph-summary",
                    label: L("Graph"),
                    value: .readOnly("\(stateCount) states, \(blendSpaceCount) blend spaces")
                ),
                EditorInspectorField(
                    id: "anim-graph-active",
                    label: L("Active"),
                    value: .readOnly(activeState.isEmpty ? L("None") : activeState)
                ),
                EditorInspectorField(
                    id: "anim-graph-previous",
                    label: L("Previous"),
                    value: .readOnly(previousState)
                ),
                EditorInspectorField(
                    id: "anim-graph-speed",
                    label: L("Speed"),
                    value: .constrainedNumber(animationGraphSpeedBinding(for: entity),
                                              min: 0, max: 10, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "anim-graph-playing",
                    label: L("Playing"),
                    value: .bool(animationGraphIsPlayingBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-graph-definition",
                    label: L("Definition"),
                    value: .json(animationGraphDefinitionBinding(for: entity), minHeight: 160)
                ),
                EditorInspectorField(
                    id: "anim-graph-parameters",
                    label: L("Parameters"),
                    value: .json(animationGraphParametersBinding(for: entity), minHeight: 84)
                ),
            ]
        )
    }

    private func animationGraphDefinitionBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let graph = scene.component(AnimationGraphPlayer.self, for: entity)?.graph else {
                    return "{}"
                }
                return formatAnimationGraph(graph)
            },
            set: { [self] next in
                guard let graph = parseAnimationGraph(next),
                      var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.graph != graph else { return }
                player.graph = graph
                player.activeState = graph.stateMachine.initialState.isEmpty ? nil : graph.stateMachine.initialState
                player.previousState = nil
                player.activeTime = 0
                player.previousTime = 0
                player.transitionElapsed = 0
                player.transitionDuration = 0
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_definition",
                                          summary: "Update animation graph definition",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func animationGraphSpeedBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AnimationGraphPlayer.self, for: entity)?.speed ?? 1
            },
            set: { [self] next in
                guard var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.speed != next else { return }
                player.speed = next
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_speed",
                                          summary: "Update animation graph speed",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func animationGraphIsPlayingBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationGraphPlayer.self, for: entity)?.isPlaying ?? false
            },
            set: { [self] next in
                guard var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.isPlaying != next else { return }
                player.isPlaying = next
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_playing",
                                          summary: "Update animation graph playing state",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func animationGraphParametersBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                formatAnimationGraphParameters(scene.component(AnimationGraphPlayer.self, for: entity)?.parameters ?? [:])
            },
            set: { [self] next in
                guard let parameters = parseAnimationGraphParameters(next),
                      var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.parameters != parameters else { return }
                player.parameters = parameters
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_parameters",
                                          summary: "Update animation graph parameters",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func formatAnimationGraph(_ graph: AnimationGraph) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(graph),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func parseAnimationGraph(_ text: String) -> AnimationGraph? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnimationGraph.self, from: data)
    }

    private func formatAnimationGraphParameters(_ parameters: [String: Float]) -> String {
        let object = Dictionary(uniqueKeysWithValues: parameters.keys.sorted().map { key in
            (key, parameters[key] ?? 0)
        })
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func parseAnimationGraphParameters(_ text: String) -> [String: Float]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: Float] = [:]
        for (key, value) in object {
            guard let number = value as? NSNumber else { return nil }
            result[key] = Float(truncating: number)
        }
        return result
    }
}
