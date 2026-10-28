import AssetPipeline
import Foundation
private import CoveFileSystem
import SIMDCompat

public enum EditorGeometryPreset: String, CaseIterable, Sendable {
    case box, plane, curve

    public var displayName: String {
        switch self { case .box: "Mesh Cube"; case .plane: "Mesh Plane"; case .curve: "Bezier Curve" }
    }

    public func document() -> GeometryDocument {
        switch self {
        case .box: return GeometryDocument(name: displayName, source: .box(size: .one))
        case .plane: return GeometryDocument(name: displayName, source: .grid(size: SIMD2(2,2), segments: SIMD2(1,1)))
        case .curve:
            let spline = BezierSpline(points: [
                .init(position: SIMD3(-1,0,0), handleIn: SIMD3(-2,0,0), handleOut: SIMD3(-0.5,1,0)),
                .init(position: SIMD3(1,0,0), handleIn: SIMD3(0.5,1,0), handleOut: SIMD3(2,0,0))])
            return GeometryDocument(name: displayName, source: .tube(spline: spline, radius: 0.1,
                radialSegments: 12, samplesPerSegment: 24, capped: true), shading: .smooth)
        }
    }
}

/// Main-thread authoring of native geometry assets. Files are committed before
/// their catalog revision is published; undo shares the scene's history order.
public final class EditorGeometryAuthoring {
    private weak var app: EditorApplication?
    private struct Cached {
        var size: Int?
        var modified: Date?
        var document: GeometryDocument
    }
    private var cache: [String: Cached] = [:]
    private var interactive: GeometryInteractiveEdit?
    private var viewportPickers: [UInt64: (mesh: PolygonMesh, world: simd_float4x4, picker: EditorMeshPicker)] = [:]

    init(app: EditorApplication) { self.app = app }

    @discardableResult
    public func create(_ preset: EditorGeometryPreset) -> UInt64? {
        guard let app, app.store.playbackState == .stopped, app.scene.isAuthoringEnabled else { return nil }
        do {
            let root = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
            let folder = root.appendingPathComponent("Assets/Geometry", isDirectory: true)
            guard PathIdentity.contains(folder, in: root, includingRoot: false) else {
                throw GeometryError.invalidParameter("geometry directory outside project")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = preset.displayName.replacingOccurrences(of: " ", with: "")
            var suffix = 1
            var url = folder.appendingPathComponent(base + ".dmesh")
            while FileManager.default.fileExists(atPath: url.path) {
                suffix += 1
                url = folder.appendingPathComponent("\(base)\(suffix).dmesh")
            }
            try preset.document().save(to: url)
            do {
                let assets = try EditorAssetCatalog.loadProject(at: app.projectDirectory)
                guard let asset = assets.first(where: { PathIdentity.sameLocation(URL(fileURLWithPath: $0.absolutePath),url) }),
                      let id = app.spawnAsset(asset) else { throw GeometryError.invalidParameter("geometry asset creation") }
                refresh()
                return id
            } catch {
                try? FileManager.default.removeItem(at: url)
                _ = try? EditorAssetCatalog.loadProject(at: app.projectDirectory)
                throw error
            }
        } catch { report(error); return nil }
    }

    public func document(for entityID: UInt64) throws -> GeometryDocument? {
        guard let asset = app?.scene.referencedAsset(for: entityID), asset.kind == .dmesh else { return nil }
        if let interactive, interactive.asset.meshIndex == asset.meshIndex { return interactive.preview }
        let url = try checkedURL(asset)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let cached = cache[url.path], cached.size == values.fileSize, cached.modified == values.contentModificationDate {
            return cached.document
        }
        let document = try GeometryDocument.load(from: url)
        cache[url.path] = Cached(size: values.fileSize, modified: values.contentModificationDate, document: document)
        return document
    }

    /// The catalog retains the exact evaluated polygons consumed by rendering.
    public func viewportPicker(for entityID: UInt64) -> EditorMeshPicker? {
        guard let app, let asset = app.scene.referencedAsset(for: entityID),
              let mesh = AssetRegistry.shared.polygonMesh(for: asset.meshIndex),
              let world = app.scene.entityWorldMatrix(entityID) else { return nil }
        if let cached = viewportPickers[entityID], cached.mesh == mesh, cached.world == world { return cached.picker }
        let scene = app.scene
        guard let picker = try? EditorMeshPicker(mesh: mesh, worldMatrix: world, occluderDistance: { [weak scene] origin, direction in
            scene?.meshSurfaceDistance(origin: origin, direction: direction, ignoringEntity: entityID)
        }) else { return nil }
        if viewportPickers.count > 128 { viewportPickers.removeAll() }
        viewportPickers[entityID] = (mesh, world, picker)
        return picker
    }

    /// Invalid edits, locked objects, playback, and unsaved text drafts cannot
    /// partially replace a source asset or add a history entry.
    @discardableResult
    public func edit(entityID: UInt64, _ update: (inout GeometryDocument) throws -> Void) -> Bool {
        guard let app, app.store.playbackState == .stopped, app.scene.isAuthoringEnabled,
              interactive == nil,
              !app.scene.isEntityLocked(entityID), let asset = app.scene.referencedAsset(for: entityID),
              asset.kind == .dmesh else { return false }
        do {
            let url = try checkedURL(asset)
            let previous = try GeometryDocument.load(from: url)
            var next = previous
            try update(&next)
            guard previous != next else { return true }
            try replace(asset: asset, expected: previous, with: next)
            let slot = asset.meshIndex
            app.scene.recordAssetEdit(undo: { [weak self] in self?.restore(slot: slot, expected: next, next: previous) ?? false },
                                      redo: { [weak self] in self?.restore(slot: slot, expected: previous, next: next) ?? false })
            refresh()
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    public func addModifier(_ operation: GeometryModifier, to entityID: UInt64) -> Bool {
        edit(entityID: entityID) { $0.modifiers.append(.init(operation)) }
    }

    @discardableResult
    public func removeModifier(_ id: String, from entityID: UInt64) -> Bool {
        edit(entityID: entityID) { document in
            guard let index = document.modifiers.firstIndex(where: { $0.id == id }) else {
                throw GeometryError.invalidParameter("missing modifier")
            }
            document.modifiers.remove(at: index)
        }
    }

    @discardableResult
    public func moveModifier(_ id: String, by offset: Int, on entityID: UInt64) -> Bool {
        edit(entityID: entityID) { document in
            guard offset == -1 || offset == 1, let index = document.modifiers.firstIndex(where: { $0.id == id }),
                  document.modifiers.indices.contains(index + offset) else {
                throw GeometryError.invalidParameter("modifier order")
            }
            document.modifiers.swapAt(index,index + offset)
        }
    }

    private func restore(slot: Int, expected: GeometryDocument, next: GeometryDocument) -> Bool {
        guard let app, app.store.playbackState == .stopped,
              let asset = EditorAssetCatalog.entries().first(where: { $0.meshIndex == slot && $0.kind == .dmesh }) else { return false }
        do { try replace(asset: asset, expected: expected, with: next); refresh(); return true }
        catch { report(error); return false }
    }

    private func replace(asset: EditorAsset, expected: GeometryDocument, with next: GeometryDocument) throws {
        guard let app else { throw GeometryError.invalidParameter("closed project") }
        let url = try checkedURL(asset)
        guard !app.workstation.documents.documents.contains(where: {
            $0.isDirty && ($0.path == asset.relativePath || $0.path == asset.absolutePath)
        }) else { throw GeometryError.invalidParameter("save or discard the open geometry text draft first") }
        guard try GeometryDocument.load(from: url) == expected else {
            throw GeometryError.invalidParameter("geometry changed on disk; history was retained")
        }
        let previousData = try Data(contentsOf: url)
        try next.save(to: url)
        do {
            let assets = try EditorAssetCatalog.loadProject(at: app.projectDirectory)
            guard assets.contains(where: { $0.meshIndex == asset.meshIndex && $0.id == asset.id }) else {
                throw GeometryError.invalidParameter("geometry catalog update")
            }
        } catch {
            try previousData.write(to: url, options: .atomic)
            _ = try? EditorAssetCatalog.loadProject(at: app.projectDirectory)
            throw error
        }
        cache.removeValue(forKey: url.path)
        app.scene.refreshAssetGeometry()
        app.workstation.documents.reloadUnmodified()
    }

    private func checkedURL(_ asset: EditorAsset) throws -> URL {
        guard let app else { throw GeometryError.invalidParameter("closed project") }
        let url = URL(fileURLWithPath: asset.absolutePath)
        guard asset.kind == .dmesh, PathIdentity.contains(url,
            in: URL(fileURLWithPath: app.projectDirectory, isDirectory: true), includingRoot: false) else {
            throw GeometryError.invalidParameter("geometry asset outside project")
        }
        return url
    }

    private func refresh() {
        app?.renderGate = EditorViewportRenderGate()
        app?.store.geometryChanged()
        app?.requestDisplayRefresh()
    }

    private func report(_ error: any Error) {
        app?.logConsole("Geometry edit failed", severity: .error, detail: String(describing: error))
        app?.store.geometryChanged()
    }
}

private struct GeometryInteractiveEdit {
    var entityID: UInt64
    var asset: EditorAsset
    var original: GeometryDocument
    var preview: GeometryDocument
}

extension EditorGeometryAuthoring {
    public var hasInteractiveEdit: Bool { interactive != nil }

    public func beginInteractiveEdit(entityID: UInt64) -> Bool {
        guard interactive == nil, let app, app.store.playbackState == .stopped,
              app.scene.isAuthoringEnabled, !app.scene.isEntityLocked(entityID),
              let asset = app.scene.referencedAsset(for: entityID), asset.kind == .dmesh else { return false }
        do {
            let document = try GeometryDocument.load(from: checkedURL(asset))
            interactive = .init(entityID: entityID,asset: asset,original: document,preview: document)
            return true
        } catch { report(error); return false }
    }

    /// Each preview starts at the original source, so cursor deltas never
    /// accumulate numerical drift. The file and undo history remain untouched.
    public func previewInteractiveEdit(_ update: (inout GeometryDocument) throws -> Void) -> Bool {
        guard var state = interactive, let app, app.store.playbackState == .stopped,
              !app.scene.isEntityLocked(state.entityID) else { return false }
        do {
            var document = state.original
            try update(&document)
            let evaluated = try document.evaluate()
            state.preview = document
            interactive = state
            AssetRegistry.shared.registerTransientMesh(evaluated.mesh,at: state.asset.meshIndex,
                assetID: state.asset.id,topologySlices: [evaluated.topologySlice],polygonMesh: evaluated.controlMesh)
            refresh()
            return true
        } catch { return false }
    }

    @discardableResult
    public func commitInteractiveEdit() -> Bool {
        guard let state = interactive else { return false }
        interactive = nil
        AssetRegistry.shared.unregisterTransientMesh(at: state.asset.meshIndex)
        let success = edit(entityID: state.entityID) { document in
            guard document == state.original else { throw GeometryError.invalidParameter("geometry changed during drag") }
            document = state.preview
        }
        if !success, let app {
            _ = try? EditorAssetCatalog.loadProject(at: app.projectDirectory)
            app.scene.refreshAssetGeometry()
        }
        refresh()
        return success
    }

    @discardableResult
    public func cancelInteractiveEdit() -> Bool {
        guard let state = interactive else { return false }
        interactive = nil
        AssetRegistry.shared.unregisterTransientMesh(at: state.asset.meshIndex)
        if let app, let url = try? checkedURL(state.asset),
           (try? GeometryDocument.load(from: url)) != state.original {
            cache.removeValue(forKey: url.path)
            _ = try? EditorAssetCatalog.loadProject(at: app.projectDirectory)
            app.scene.refreshAssetGeometry()
            app.workstation.documents.reloadUnmodified()
        }
        refresh()
        return true
    }
}
