import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func destructibleSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(Destructible.self, for: entity) else { return nil }
        let authored = scene.component(Destructible.self, for: entity)
        let asset = authored.flatMap {
            scene.resource(DestructibleAssetResource.self)?.asset(for: $0.assetResourceID)
        }
        let state = scene.destructionStateFrame.sources[entity]
        return EditorInspectorSection(
            id: "destructible",
            title: L("Destructible"),
            fields: [
                EditorInspectorField(
                    id: "destructible-enabled", label: L("Enabled"),
                    value: .bool(destructibleBoolBinding(for: entity, \.isEnabled))
                ),
                EditorInspectorField(
                    id: "destructible-asset", label: L("Pre-fractured Asset"),
                    value: .text(destructibleAssetBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "destructible-damage-threshold", label: L("Damage Threshold"),
                    value: .constrainedNumber(
                        destructibleFloatBinding(for: entity, \.damageThreshold),
                        min: 0, max: nil, step: 1, showsStepper: true
                    )
                ),
                EditorInspectorField(
                    id: "destructible-impulse-threshold", label: L("Impulse Threshold"),
                    value: .constrainedNumber(
                        destructibleFloatBinding(for: entity, \.impulseThreshold),
                        min: 0, max: nil, step: 1, showsStepper: true
                    )
                ),
                EditorInspectorField(
                    id: "destructible-fragment-budget", label: L("Fragment Budget"),
                    value: .constrainedNumber(
                        destructibleBudgetBinding(for: entity),
                        min: 0, max: nil, step: 1, showsStepper: true
                    )
                ),
                EditorInspectorField(
                    id: "destructible-lifetime", label: L("Maximum Lifetime"),
                    value: .constrainedNumber(
                        destructibleFloatBinding(for: entity, \.maximumFragmentLifetimeSeconds),
                        min: 0, max: nil, step: 1, showsStepper: true
                    )
                ),
                EditorInspectorField(
                    id: "destructible-sleep-recycle", label: L("Sleeping Recycle Delay"),
                    value: .constrainedNumber(
                        destructibleFloatBinding(for: entity, \.sleepingRecycleDelaySeconds),
                        min: 0, max: nil, step: 0.5, showsStepper: true
                    )
                ),
                EditorInspectorField(
                    id: "destructible-separation-impulse", label: L("Separation Impulse"),
                    value: .constrainedNumber(
                        destructibleFloatBinding(for: entity, \.separationImpulse),
                        min: 0, max: nil, step: 0.05, showsStepper: true
                    )
                ),
                EditorInspectorField(
                    id: "destructible-asset-fragments", label: L("Asset Fragments"),
                    value: .readOnly(String(asset?.fragments.count ?? 0))
                ),
                EditorInspectorField(
                    id: "destructible-asset-connections", label: L("Asset Connections"),
                    value: .readOnly(String(asset?.connections.count ?? 0))
                ),
                EditorInspectorField(
                    id: "destructible-active-fragments", label: L("Active Fragments"),
                    value: .readOnly(String(state?.activeFragmentEntities.count ?? 0))
                ),
                EditorInspectorField(
                    id: "destructible-retained-fragments", label: L("Retained Fragments"),
                    value: .readOnly(String(state?.retainedFragmentIDs.count ?? 0))
                ),
                EditorInspectorField(
                    id: "destructible-released-fragments", label: L("Released Fragments"),
                    value: .readOnly(String(state?.releasedFragmentIDs.count ?? 0))
                ),
                EditorInspectorField(
                    id: "destructible-fracture-state", label: L("Fracture State"),
                    value: .readOnly(
                        state?.isFullyFractured == true ? L("Fully Fractured")
                            : state?.hasFractured == true ? L("Partially Fractured")
                            : L("Intact")
                    )
                ),
                EditorInspectorField(
                    id: "destructible-broken-connections", label: L("Broken Connections"),
                    value: .readOnly(String(state?.brokenConnectionIDs.count ?? 0))
                ),
            ]
        )
    }

    private func destructibleAssetBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(Destructible.self, for: entity)?.assetResourceID ?? ""
            },
            set: { [self] value in
                guard scene.updateComponent(Destructible.self, for: entity, {
                    $0.assetResourceID = value
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func destructibleFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<Destructible, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Destructible.self, for: entity)?[keyPath: keyPath] ?? 0
            },
            set: { [self] value in
                guard value.isFinite else { return }
                guard scene.updateComponent(Destructible.self, for: entity, {
                    $0[keyPath: keyPath] = max(0, value)
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func destructibleBoolBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<Destructible, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Destructible.self, for: entity)?[keyPath: keyPath] ?? false
            },
            set: { [self] value in
                guard scene.updateComponent(Destructible.self, for: entity, {
                    $0[keyPath: keyPath] = value
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func destructibleBudgetBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(Destructible.self, for: entity)?.fragmentBudget ?? 0)
            },
            set: { [self] value in
                guard value.isFinite else { return }
                let rounded = value.rounded()
                let budget = Int(exactly: rounded).map { max(0, $0) }
                    ?? (rounded > 0 ? Int.max : 0)
                guard scene.updateComponent(Destructible.self, for: entity, {
                    $0.fragmentBudget = budget
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }
}
