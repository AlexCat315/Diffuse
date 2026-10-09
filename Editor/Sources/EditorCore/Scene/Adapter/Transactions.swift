import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    @discardableResult
    func setComponentData<Component: RuntimeComponent>(_ component: Component, for entity: EntityID) -> Bool {
        guard let schema = scene.componentRegistry.schema(for: Component.self) else { return false }
        var prepared = scene
        guard prepared.setComponent(component, for: entity),
              let value = prepared.componentData(schema.typeID, for: entity) else { return false }
        return applySceneTransaction(intentVerb: "scene.set_component_data", summary: "Update \(schema.displayName)",
            targetRawIDs: [entity.rawValue],
            mutations: [.setComponentData(entityID: entity.rawValue, typeID: schema.typeID, value: value)]) != nil
    }

    @discardableResult
    func updateComponentData<Component: RuntimeComponent>(_ type: Component.Type, for entity: EntityID,
                                                          _ update: (inout Component) -> Void) -> Bool {
        guard var component = scene.component(type, for: entity) else { return false }
        update(&component)
        return setComponentData(component, for: entity)
    }

    @discardableResult
    func applySceneTransaction(intentVerb: String,
                               summary: String,
                               targetRawIDs: [UInt64] = [],
                               mutations: [SceneMutation]) -> TransactionApplyResult? {
        guard isAuthoringEnabled else {
            onTransactionError?("\(summary): stop simulation before editing the scene")
            return nil
        }
        let lockedTargets = targetRawIDs.filter { isEntityLocked($0) }
        guard lockedTargets.isEmpty else {
            onTransactionError?("\(summary): entity is locked (\(lockedTargets.map(String.init).joined(separator: ", ")))")
            return nil
        }
        let intent = IntentIR(verb: intentVerb,
                              summary: summary,
                              targetObjectIDs: targetRawIDs.map { "scene:\($0)" },
                              source: .human)
        let transaction = TransactionIR(intent: intent,
                                        summary: summary,
                                        operations: mutations.map(TransactionOperation.scene),
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result: TransactionApplyResult
        do {
            result = try transactionExecutor.apply(transaction, to: &context)
        } catch {
            onTransactionError?("\(summary): \(error)")
            return nil
        }
        guard let updatedScene = context.sceneRuntime else {
            onTransactionError?("\(summary): transaction completed without a scene result")
            return nil
        }
        scene = updatedScene
        let keys = mutations.compactMap(\.componentKey)
        notifyRevisionChanged(componentKeys: keys.count == mutations.count ? Set(keys) : nil)
        return result
    }
}
