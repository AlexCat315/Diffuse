import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    /// 把资产生成到场景中，并把新实体设为当前选中。
    @discardableResult
    public func spawnAsset(_ asset: EditorAsset, at position: SIMD3<Float> = .zero) -> UInt64? {
        guard asset.kind.isMesh else {
            logConsole("Cannot spawn \(asset.name)", severity: .warning, detail: asset.kind.sceneKindLabel)
            return nil
        }
        guard let id = scene.spawnEntity(from: asset, at: position) else {
            logConsole("Failed to spawn \(asset.name)", severity: .error)
            return nil
        }
        store.dispatch(.setSelectedEntity(id))
        logConsole("Spawned \(asset.name)", detail: "entity \(id)")
        runSemanticAnnotation(entityID: id, asset: asset)
        return id
    }

    /// Adds a mesh selection to the scene as one grouped operation and selects
    /// every created entity. Invalid batches are rejected before any mutation.
    @discardableResult
    public func spawnAssets(_ assets: [EditorAsset], at position: SIMD3<Float> = .zero) -> [UInt64]? {
        guard store.state.playbackState == .stopped else {
            logConsole("Stop simulation before adding assets to the scene", severity: .warning)
            return nil
        }
        guard !assets.isEmpty, assets.allSatisfy({ $0.kind.isMesh }) else {
            logConsole("Select only mesh assets to add them to the scene", severity: .warning)
            return nil
        }
        guard let entityIDs = scene.spawnEntities(from: assets, at: position) else {
            logConsole("Failed to add selected assets to the scene", severity: .error)
            return nil
        }

        store.dispatch(.setSelectedEntities(Set(entityIDs)))
        for (entityID, asset) in zip(entityIDs, assets) {
            logConsole("Spawned \(asset.name)", detail: "entity \(entityID)")
            runSemanticAnnotation(entityID: entityID, asset: asset)
        }
        return entityIDs
    }

    private func runSemanticAnnotation(entityID: UInt64, asset: EditorAsset) {
        guard let mesh = AssetRegistry.shared.meshAsset(for: asset.meshIndex) else { return }
        let entityRef = "scene:\(entityID)"
        let assetURI = asset.relativePath

        let previewImagePath = Self.siblingPreviewImagePath(for: asset.absolutePath)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let raw = Self.buildRawStructure(from: mesh, assetURI: assetURI,
                                             previewImagePath: previewImagePath)
            let signals = Self.buildGeometrySignals(from: mesh, assetURI: assetURI)
            let pipeline = AssetSemanticPipeline.standard()
            let decision = await pipeline.run(rawStructure: raw, signals: signals)

            let proposals: [SemanticProposal]
            switch decision {
            case let .autoCommit(committed): proposals = committed
            case .needsConfirmation: return
            }

            guard !proposals.isEmpty else { return }
            let events = SemanticWorldEventMapper().makeWorldEvents(from: proposals, targetRef: entityRef)
            guard !events.isEmpty else { return }

            await MainActor.run {
                guard !self.isShuttingDown else { return }
                self.observeWorldEvents(events)
                self.logConsole("Semantic annotations applied to \(entityRef)",
                                detail: "\(proposals.count) proposals")
            }
        }
    }

    private static func siblingPreviewImagePath(for absolutePath: String) -> String? {
        let base = (absolutePath as NSString).deletingPathExtension
        for ext in ["png", "jpg", "jpeg", "PNG", "JPG", "JPEG"] {
            let candidate = "\(base).\(ext)"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func buildRawStructure(from mesh: MeshAsset,
                                          assetURI: String,
                                          previewImagePath: String? = nil) -> RawStructure {
        var nodes: [RawStructure.Node] = []
        for (i, node) in mesh.nodes.enumerated() {
            let t = node.localTranslation
            let s = node.localScale
            // Column-major 4×4 from TRS (simplified; rotation from quaternion)
            let transform: [Float] = [
                s.x, 0, 0, 0,
                0, s.y, 0, 0,
                0, 0, s.z, 0,
                t.x, t.y, t.z, 1,
            ]
            nodes.append(RawStructure.Node(id: "node_\(i)",
                                           name: node.name ?? "node_\(i)",
                                           parentID: node.parentIndex.map { "node_\($0)" },
                                           localTransform: transform))
        }

        let meshRecord = RawStructure.MeshRecord(id: "mesh_0",
                                                 nodeID: nodes.first?.id ?? "node_0",
                                                 vertexCount: mesh.vertexCount,
                                                 faceCount: mesh.triangleCount)

        var submeshRecords: [RawStructure.SubmeshRecord] = []
        for (i, sub) in mesh.submeshes.enumerated() {
            submeshRecords.append(RawStructure.SubmeshRecord(id: "sub_\(i)",
                                                             meshID: "mesh_0",
                                                             materialSlot: sub.materialIndex,
                                                             indexStart: Int(sub.indexStart),
                                                             indexCount: Int(sub.indexCount)))
        }

        var materialSlots: [RawStructure.MaterialSlot] = []
        for (i, mat) in mesh.materials.enumerated() {
            materialSlots.append(RawStructure.MaterialSlot(id: "mat_\(i)",
                                                           name: mat.name ?? "material_\(i)",
                                                           sourceIndex: i))
        }

        var bones: [RawStructure.Bone] = []
        for skin in mesh.skins {
            for jointIndex in skin.jointNodeIndices {
                guard jointIndex < mesh.nodes.count else { continue }
                let node = mesh.nodes[jointIndex]
                let boneID = "bone_\(jointIndex)"
                let parentBoneID: String? = {
                    guard let parentIdx = node.parentIndex,
                          skin.jointNodeIndices.contains(parentIdx) else { return nil }
                    return "bone_\(parentIdx)"
                }()
                bones.append(RawStructure.Bone(id: boneID,
                                               name: node.name ?? boneID,
                                               parentID: parentBoneID))
            }
        }
        let skeleton: RawStructure.Skeleton? = bones.isEmpty ? nil : RawStructure.Skeleton(bones: bones)

        return RawStructure(assetURI: assetURI,
                            previewImagePath: previewImagePath,
                            nodes: nodes,
                            meshes: [meshRecord],
                            submeshes: submeshRecords,
                            materialSlots: materialSlots,
                            skeleton: skeleton)
    }

    private static func buildGeometrySignals(from mesh: MeshAsset, assetURI: String) -> GeometrySignals {
        let bounds = mesh.localBounds
        let aabb = GeometrySignals.AABB(
            min: (bounds.min.x, bounds.min.y, bounds.min.z),
            max: (bounds.max.x, bounds.max.y, bounds.max.z)
        )
        let component = GeometrySignals.ConnectedComponent(
            id: "cc_0",
            meshID: "mesh_0",
            faceCount: mesh.triangleCount,
            bounds: aabb
        )
        let dx = bounds.max.x - bounds.min.x
        let dy = bounds.max.y - bounds.min.y
        let dz = bounds.max.z - bounds.min.z
        let surfaceArea = 2 * (dx * dy + dy * dz + dx * dz)
        let volumeEstimate = dx * dy * dz
        return GeometrySignals(assetURI: assetURI,
                               connectedComponents: [component],
                               surfaceArea: surfaceArea,
                               volumeEstimate: volumeEstimate)
    }

    /// Runs visual perception on `imageURL` and injects the resulting inferred properties
    /// into the World and the active Session for the given entity.
    /// Call this from the UI or MCP after the user selects a reference image for an entity.
    public func tagEntity(_ entityRef: String, imageURL: URL) {
        let ps = perceptionService
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let events = try await ps.tag(entityRef: entityRef, imageURL: imageURL)
                guard !self.isShuttingDown else { return }
                self.observeWorldEvents(events)
                self.logConsole("Tagged \(entityRef)",
                                detail: "\(events.count) inferred properties")
            } catch {
                guard !self.isShuttingDown else { return }
                self.logConsole("Perception unavailable for \(entityRef)",
                                severity: .warning,
                                detail: error.localizedDescription)
            }
        }
    }

    @discardableResult
    public func reloadAssets() -> Int? {
        do {
            let assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
            reloadProjectScripts(force: true)
            store.dispatch(.forceUIRefresh)
            logConsole("Reloaded assets", detail: "\(assets.count) importable files")
            return assets.count
        } catch {
            logConsole("Failed to reload assets",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }
}
