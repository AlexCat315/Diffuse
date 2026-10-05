import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func audioListenerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AudioListener.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "audio-listener",
            title: L("Audio Listener"),
            fields: [
                EditorInspectorField(
                    id: "audio-listener-volume",
                    label: L("Master Volume"),
                    value: .constrainedNumber(audioListenerVolumeBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
            ]
        )
    }

    private func audioListenerVolumeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioListener.self, for: entity)?.masterVolume ?? 1
            },
            set: { [self] next in
                guard let listener = scene.component(AudioListener.self, for: entity),
                      listener.masterVolume != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_audio_listener",
                                          summary: "Update audio listener volume",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioListener(entityID: entity.rawValue, masterVolume: next)])
            }
        )
    }

    func audioSourceSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AudioSource.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "audio-source",
            title: L("Audio Source"),
            fields: [
                EditorInspectorField(
                    id: "audio-clip",
                    label: L("Clip"),
                    value: .text(audioClipNameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-volume",
                    label: L("Volume"),
                    value: .constrainedNumber(audioVolumeBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "audio-pitch",
                    label: L("Pitch"),
                    value: .constrainedNumber(audioPitchBinding(for: entity),
                                              min: 0.1, max: 3, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "audio-loop",
                    label: L("Loop"),
                    value: .bool(audioLoopBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-play-on-awake",
                    label: L("Play on Awake"),
                    value: .bool(audioPlayOnAwakeBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-spatial-blend",
                    label: L("Spatial Blend"),
                    value: .constrainedNumber(audioSpatialBlendBinding(for: entity),
                                              min: 0, max: 1, step: 0.1, showsStepper: true)
                ),
            ]
        )
    }

    private func audioClipNameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.clipName ?? ""
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.clipName != next else { return }
                source.clipName = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_clip",
                                          summary: "Update audio clip",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioVolumeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.volume ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.volume != next else { return }
                source.volume = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_volume",
                                          summary: "Update audio volume",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioPitchBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.pitch ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.pitch != next else { return }
                source.pitch = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_pitch",
                                          summary: "Update audio pitch",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioLoopBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.loop ?? false
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.loop != next else { return }
                source.loop = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_loop",
                                          summary: "Update audio loop",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioPlayOnAwakeBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.playOnAwake ?? true
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.playOnAwake != next else { return }
                source.playOnAwake = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_play_on_awake",
                                          summary: "Update audio play on awake",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioSpatialBlendBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.spatialBlend ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.spatialBlend != next else { return }
                source.spatialBlend = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_spatial_blend",
                                          summary: "Update audio spatial blend",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }
}
