import Foundation
import SIMDCompat

extension BuiltinComponentCodecs {
    static func serializeAudioSource(_ c: AudioSource) -> [String: Any] {
        [
            "clipName": c.clipName,
            "volume": c.volume,
            "pitch": c.pitch,
            "loop": c.loop,
            "playOnAwake": c.playOnAwake,
            "spatialBlend": c.spatialBlend,
        ]
    }

    static func deserializeAudioSource(_ d: [String: Any]) -> AudioSource {
        AudioSource(
            clipName: jsonToString(d["clipName"]) ?? "",
            volume: jsonToFloat(d["volume"]) ?? 1,
            pitch: jsonToFloat(d["pitch"]) ?? 1,
            loop: jsonToBool(d["loop"]) ?? false,
            playOnAwake: jsonToBool(d["playOnAwake"]) ?? true,
            spatialBlend: jsonToFloat(d["spatialBlend"]) ?? 1
        )
    }

    static func serializeAnimationPlayer(_ c: AnimationPlayer) -> [String: Any] {
        var d: [String: Any] = ["isPlaying": c.isPlaying, "loop": c.loop, "speed": c.speed, "time": c.time]
        if let name = c.clipName { d["clipName"] = name }
        return d
    }

    static func deserializeAnimationPlayer(_ d: [String: Any]) -> AnimationPlayer {
        AnimationPlayer(
            clipName: jsonToString(d["clipName"]),
            speed: jsonToFloat(d["speed"]) ?? 1,
            loop: jsonToBool(d["loop"]) ?? true,
            isPlaying: jsonToBool(d["isPlaying"]) ?? true,
            time: (d["time"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    static func mergeAnimationPlayer(_ previous: ComponentValue, _ changes: ComponentValue) throws -> ComponentValue {
        let merged = try previous.merging(changes)
        guard case let .object(changes) = changes, let clip = changes["clipName"],
              clip != (previous.value(at: ["clipName"]) ?? .null), changes["time"] == nil,
              case var .object(fields) = merged else { return merged }
        // Switching clips restarts playback. Other controls retain progress;
        // an explicitly supplied playhead is honored by transaction callers.
        fields["time"] = .number(0)
        return .object(fields)
    }

    static func serializeAnimationGraphPlayer(_ c: AnimationGraphPlayer) -> [String: Any] {
        var d: [String: Any] = [
            "graph": serializeAnimationGraph(c.graph),
            "parameters": c.parameters,
            "activeTime": c.activeTime,
            "previousTime": c.previousTime,
            "transitionElapsed": c.transitionElapsed,
            "transitionDuration": c.transitionDuration,
            "speed": c.speed,
            "isPlaying": c.isPlaying,
        ]
        if let activeState = c.activeState { d["activeState"] = activeState }
        if let previousState = c.previousState { d["previousState"] = previousState }
        return d
    }

    static func deserializeAnimationGraphPlayer(_ d: [String: Any]) -> AnimationGraphPlayer {
        AnimationGraphPlayer(
            graph: jsonToDict(d["graph"]).map(deserializeAnimationGraph)
                ?? AnimationGraph(stateMachine: AnimationStateMachine(initialState: "", states: [])),
            parameters: jsonToStringFloatDict(d["parameters"]) ?? [:],
            activeState: jsonToString(d["activeState"]),
            previousState: jsonToString(d["previousState"]),
            activeTime: jsonToDouble(d["activeTime"]) ?? 0,
            previousTime: jsonToDouble(d["previousTime"]) ?? 0,
            transitionElapsed: jsonToDouble(d["transitionElapsed"]) ?? 0,
            transitionDuration: jsonToDouble(d["transitionDuration"]) ?? 0,
            speed: jsonToFloat(d["speed"]) ?? 1,
            isPlaying: jsonToBool(d["isPlaying"]) ?? true
        )
    }

    static func serializeAnimationGraph(_ graph: AnimationGraph) -> [String: Any] {
        [
            "blendSpaces1D": graph.blendSpaces1D.map(serializeAnimationBlendSpace1D),
            "stateMachine": serializeAnimationStateMachine(graph.stateMachine),
        ]
    }

    static func deserializeAnimationGraph(_ d: [String: Any]) -> AnimationGraph {
        AnimationGraph(
            blendSpaces1D: jsonToArray(d["blendSpaces1D"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationBlendSpace1D)
            } ?? [],
            stateMachine: jsonToDict(d["stateMachine"]).map(deserializeAnimationStateMachine)
                ?? AnimationStateMachine(initialState: "", states: [])
        )
    }

    static func serializeAnimationBlendSpace1D(_ blendSpace: AnimationBlendSpace1D) -> [String: Any] {
        [
            "name": blendSpace.name,
            "parameter": blendSpace.parameter,
            "samples": blendSpace.samples.map(serializeAnimationBlendSample1D),
        ]
    }

    static func deserializeAnimationBlendSpace1D(_ d: [String: Any]) -> AnimationBlendSpace1D {
        AnimationBlendSpace1D(
            name: jsonToString(d["name"]) ?? "",
            parameter: jsonToString(d["parameter"]) ?? "",
            samples: jsonToArray(d["samples"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationBlendSample1D)
            } ?? []
        )
    }

    static func serializeAnimationBlendSample1D(_ sample: AnimationBlendSample1D) -> [String: Any] {
        var d: [String: Any] = ["threshold": sample.threshold]
        if let clipName = sample.clipName { d["clipName"] = clipName }
        return d
    }

    static func deserializeAnimationBlendSample1D(_ d: [String: Any]) -> AnimationBlendSample1D {
        AnimationBlendSample1D(
            clipName: jsonToString(d["clipName"]),
            threshold: jsonToFloat(d["threshold"]) ?? 0
        )
    }

    static func serializeAnimationStateMachine(_ stateMachine: AnimationStateMachine) -> [String: Any] {
        [
            "initialState": stateMachine.initialState,
            "states": stateMachine.states.map(serializeAnimationState),
            "transitions": stateMachine.transitions.map(serializeAnimationTransition),
        ]
    }

    static func deserializeAnimationStateMachine(_ d: [String: Any]) -> AnimationStateMachine {
        AnimationStateMachine(
            initialState: jsonToString(d["initialState"]) ?? "",
            states: jsonToArray(d["states"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationState)
            } ?? [],
            transitions: jsonToArray(d["transitions"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationTransition)
            } ?? []
        )
    }

    static func serializeAnimationState(_ state: AnimationState) -> [String: Any] {
        [
            "name": state.name,
            "motion": serializeAnimationMotion(state.motion),
            "speed": state.speed,
            "loop": state.loop,
        ]
    }

    static func deserializeAnimationState(_ d: [String: Any]) -> AnimationState {
        AnimationState(
            name: jsonToString(d["name"]) ?? "",
            motion: jsonToDict(d["motion"]).map(deserializeAnimationMotion) ?? .clip(nil),
            speed: jsonToFloat(d["speed"]) ?? 1,
            loop: jsonToBool(d["loop"]) ?? true
        )
    }

    static func serializeAnimationMotion(_ motion: AnimationMotion) -> [String: Any] {
        switch motion {
        case let .clip(clipName):
            var d: [String: Any] = ["type": "clip"]
            if let clipName { d["clipName"] = clipName }
            return d
        case let .blendSpace1D(name):
            return ["type": "blendSpace1D", "name": name]
        }
    }

    static func deserializeAnimationMotion(_ d: [String: Any]) -> AnimationMotion {
        switch jsonToString(d["type"]) {
        case "blendSpace1D":
            return .blendSpace1D(jsonToString(d["name"]) ?? "")
        default:
            return .clip(jsonToString(d["clipName"]))
        }
    }

    static func serializeAnimationTransition(_ transition: AnimationTransition) -> [String: Any] {
        [
            "from": transition.from,
            "to": transition.to,
            "parameter": transition.parameter,
            "comparison": transition.comparison.rawValue,
            "threshold": transition.threshold,
            "duration": transition.duration,
        ]
    }

    static func deserializeAnimationTransition(_ d: [String: Any]) -> AnimationTransition {
        AnimationTransition(
            from: jsonToString(d["from"]) ?? "",
            to: jsonToString(d["to"]) ?? "",
            parameter: jsonToString(d["parameter"]) ?? "",
            comparison: AnimationTransitionComparison(rawValue: jsonToString(d["comparison"]) ?? "")
                ?? .greaterThan,
            threshold: jsonToFloat(d["threshold"]) ?? 0,
            duration: jsonToDouble(d["duration"]) ?? 0
        )
    }

    static func serializeAudioListener(_ c: AudioListener) -> [String: Any] {
        ["masterVolume": c.masterVolume]
    }

    static func deserializeAudioListener(_ d: [String: Any]) -> AudioListener {
        AudioListener(masterVolume: jsonToFloat(d["masterVolume"]) ?? 1)
    }
}
