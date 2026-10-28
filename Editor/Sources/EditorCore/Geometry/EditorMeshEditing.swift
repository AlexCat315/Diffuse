import AssetPipeline
import CoveUICompose
import EngineKernel
import Foundation
import SIMDCompat

/// Transient selection state belongs to the editor; authored control vertices
/// and topology continue to live in the native asset and unified edit history.
public final class EditorMeshEditing {
    weak var app: EditorApplication?
    public private(set) var entityID: UInt64?
    public private(set) var mode: EditorMeshSelectionMode = .object
    public private(set) var selection: Set<Int> = []
    public private(set) var xray = false
    public private(set) var showsEvaluatedWireframe = true
    public var extrusionDistance: Float = 0.25
    public var extrusionDirection: EditorMeshExtrusionDirection = .normal
    public let pointer = EditorMeshPointerSession()
    private var topology: [[Int]] = []
    private var vertexCount = 0
    private var cachedPicker: (mesh: PolygonMesh,world: simd_float4x4,picker: EditorMeshPicker)?
    private var transformVertices: Set<Int>?
    var insetFaces: Set<Int>?
    public internal(set) var insetDistance: Float = 0.1
    public internal(set) var isInsetPreviewValid = false

    init(app: EditorApplication) { self.app = app }
    public var isEditing: Bool { entityID != nil && mode != .object }
    public var isTransforming: Bool { transformVertices != nil }
    public var isInsetting: Bool { insetFaces != nil }
    public var hasInteractiveEdit: Bool { isTransforming || isInsetting }

    public var canEnter: Bool {
        guard let app, app.store.playbackState == .stopped, let id = app.store.selectedEntityID,
              !app.scene.isEntityLocked(id), app.scene.isAuthoringEnabled else { return false }
        return app.scene.referencedAsset(for: id)?.kind == .dmesh
    }

    @discardableResult
    public func setMode(_ next: EditorMeshSelectionMode) -> Bool {
        if next == .object { leave(); return true }
        guard canEnter, let app, let id = app.store.selectedEntityID else { return false }
        if entityID == id, mode == next { return true }
        _ = cancelInteractiveEdit()
        if entityID != id || !isEditing {
            guard app.geometryAuthoring.edit(entityID: id,{ document in
                if case .polygon = document.source { return }
                document.source = .polygon(mesh: try document.source.evaluate())
            }) else { return false }
        }
        entityID = id; mode = next; selection = []
        if let mesh = controlMesh() { rememberTopology(mesh) }
        refresh()
        return true
    }

    public func synchronize() {
        guard isEditing else { return }
        guard canEnter, let app, app.store.selectedEntityID == entityID, let mesh = controlMesh() else { leave(); return }
        if !isInsetting, vertexCount != mesh.positions.count || topology != mesh.faces.map(\.vertices) {
            _ = cancelTransform()
            selection = []
            rememberTopology(mesh)
        }
    }

    public func leave() {
        _ = cancelInteractiveEdit()
        pointer.clear()
        entityID = nil; mode = .object; selection = []; topology = []; vertexCount = 0; cachedPicker = nil
        refresh()
    }

    public func setXray(_ enabled: Bool) { xray = enabled; refresh() }
    public func setEvaluatedWireframe(_ enabled: Bool) { showsEvaluatedWireframe = enabled; refresh() }

    public var hasModifiers: Bool {
        guard let id = entityID, let document = try? app?.geometryAuthoring.document(for: id) else { return false }
        return document.modifiers.contains(where: \.enabled)
    }

    @discardableResult
    public func applyModifiers() -> Bool {
        synchronize()
        guard !hasInteractiveEdit, let app, let id = entityID,
              let document = try? app.geometryAuthoring.document(for: id), let last = document.modifiers.last else { return false }
        let success = app.geometryAuthoring.applyModifier(last.id,on: id)
        if success { synchronize(); refresh() }
        return success
    }

    @discardableResult
    public func subdivideSelection() -> Bool { editFaces { try $0.subdivide(faces: $1) } }

    @discardableResult
    public func triangulateSelection() -> Bool { editFaces { try $0.triangulateFaces($1) } }

    @discardableResult
    public func deleteSelection() -> Bool {
        editComponents { mesh, mode, selected in
            switch mode {
            case .vertex: try mesh.delete(vertices: selected)
            case .edge:
                let edges = mesh.edges
                try mesh.delete(edges: Set(selected.map { edges[$0] }))
            case .face: try mesh.delete(faces: selected)
            case .object: return []
            }
            return []
        }
    }

    @discardableResult
    public func dissolveSelection() -> Bool {
        guard mode == .edge else { return false }
        return editComponents { mesh, _, selected in
            let edges = mesh.edges
            _ = try mesh.dissolve(edges: Set(selected.map { edges[$0] }))
            return []
        }
    }

    private func editFaces(_ update: (inout PolygonMesh, Set<Int>) throws -> Set<Int>) -> Bool {
        guard mode == .face else { return false }
        return editComponents { mesh, _, selected in try update(&mesh,selected) }
    }

    private func editComponents(_ update: (inout PolygonMesh, EditorMeshSelectionMode, Set<Int>) throws -> Set<Int>) -> Bool {
        synchronize()
        guard !hasInteractiveEdit, isEditing, !selection.isEmpty, let app, let id = entityID else { return false }
        let previous = selection, previousMode = mode
        var next: Set<Int> = []
        let success = app.geometryAuthoring.edit(entityID: id) { document in
            guard case var .polygon(mesh) = document.source else { return }
            next = try update(&mesh,previousMode,previous)
            document.source = .polygon(mesh: mesh)
        }
        if success, let mesh = controlMesh() { rememberTopology(mesh); selection = next; refresh() }
        return success
    }

    public func select(_ indices: Set<Int>, extending: Bool = false, toggling: Bool = false) {
        synchronize()
        guard isEditing, !hasInteractiveEdit, let picker = picker() else { return }
        let count = mode == .vertex ? picker.positions.count : (mode == .edge ? picker.edges.count : picker.mesh.faces.count)
        let valid = indices.filter { (0..<count).contains($0) }
        if toggling { selection.formSymmetricDifference(valid) }
        else if extending { selection.formUnion(valid) }
        else { selection = valid }
        refresh()
    }

    public func selectAll() {
        guard let picker = picker() else { return }
        let count = mode == .vertex ? picker.positions.count : (mode == .edge ? picker.edges.count : picker.mesh.faces.count)
        select(Set(0..<count))
    }

    public func invertSelection() {
        guard !hasInteractiveEdit else { return }
        let previous = selection
        selectAll()
        selection.subtract(previous)
        refresh()
    }

    public func controlMesh() -> PolygonMesh? {
        guard let id = entityID, let document = try? app?.geometryAuthoring.document(for: id),
              case let .polygon(mesh) = document.source else { return nil }
        return mesh
    }

    public func picker() -> EditorMeshPicker? {
        guard let app, let id = entityID, let mesh = controlMesh(), let world = app.scene.entityWorldMatrix(id) else { return nil }
        if let cache = cachedPicker, cache.mesh == mesh, cache.world == world { return cache.picker }
        let scene = app.scene
        guard let picker = try? EditorMeshPicker(mesh: mesh,worldMatrix: world,occluderDistance: { [weak scene] origin,direction in
            scene?.meshSurfaceDistance(origin: origin,direction: direction,ignoringEntity: id)
        }) else { return nil }
        cachedPicker = (mesh,world,picker)
        return picker
    }

    public var selectedVertices: Set<Int> {
        guard let picker = picker() else { return [] }
        switch mode {
        case .vertex: return Set(selection.filter { picker.positions.indices.contains($0) })
        case .edge: return Set(selection.filter { picker.edges.indices.contains($0) }.flatMap { [picker.edges[$0].a,picker.edges[$0].b] })
        case .face: return Set(selection.filter { picker.mesh.faces.indices.contains($0) }.flatMap { picker.mesh.faces[$0].vertices })
        case .object: return []
        }
    }

    public var selectionCenter: SIMD3<Float>? {
        guard let mesh = controlMesh() else { return nil }
        let vertices = selectedVertices.sorted()
        guard !vertices.isEmpty else { return nil }
        return vertices.reduce(SIMD3<Float>.zero) { $0+mesh.positions[$1]/Float(vertices.count) }
    }

    public func moveSelectionCenter(to position: SIMD3<Float>) -> Bool {
        synchronize()
        guard !hasInteractiveEdit, let app, let id = entityID, let center = selectionCenter else { return false }
        let vertices = selectedVertices
        return app.geometryAuthoring.edit(entityID: id) { doc in
            guard case var .polygon(mesh) = doc.source else { return }
            try mesh.translate(vertices: vertices,by: position-center)
            doc.source = .polygon(mesh: mesh)
        }
    }

    public func extrudeRegion() -> Bool {
        synchronize()
        guard !hasInteractiveEdit, let app, let id = entityID, mode == .face, !selection.isEmpty, let mesh = controlMesh() else { return false }
        var normal = SIMD3<Float>.zero
        for index in selection.sorted() where mesh.faces.indices.contains(index) {
            let vertices = mesh.faces[index].vertices, origin = mesh.positions[vertices[0]]
            for i in vertices.indices {
                normal += simd_cross(mesh.positions[vertices[i]]-origin,mesh.positions[vertices[(i+1)%vertices.count]]-origin)
            }
        }
        let length = simd_length(normal)
        guard extrusionDistance.isFinite, extrusionDistance != 0 else { return false }
        switch extrusionDirection {
        case .normal:
            guard length.isFinite, length > 1e-8 else {
                app.logConsole("Choose an extrusion axis for a selection without a common normal",severity: .info)
                return false
            }
            normal /= length
        case .x: normal = SIMD3(1,0,0)
        case .y: normal = SIMD3(0,1,0)
        case .z: normal = SIMD3(0,0,1)
        }
        let selected = selection, offset = normal*extrusionDistance
        let success = app.geometryAuthoring.edit(entityID: id) { doc in
            guard case var .polygon(mesh) = doc.source else { return }
            try mesh.extrude(faces: selected,by: offset)
            doc.source = .polygon(mesh: mesh)
        }
        if success, let result = controlMesh() { rememberTopology(result); refresh() }
        return success
    }

    public func beginTransform() -> Bool {
        synchronize()
        guard !hasInteractiveEdit, let app, let id = entityID, isEditing, !selectedVertices.isEmpty,
              app.geometryAuthoring.beginInteractiveEdit(entityID: id) else { return false }
        transformVertices = selectedVertices
        return true
    }

    public func previewTransform(_ localDelta: simd_float4x4) -> Bool {
        guard let vertices = transformVertices else { return false }
        return app?.geometryAuthoring.previewInteractiveEdit { document in
            guard case var .polygon(mesh) = document.source else { return }
            try mesh.transform(vertices: vertices,by: localDelta)
            document.source = .polygon(mesh: mesh)
        } ?? false
    }

    @discardableResult
    public func finishTransform() -> Bool {
        guard transformVertices != nil else { return false }
        transformVertices = nil
        EditorGizmoController.shared.clearDrag()
        pointer.clear()
        return app?.geometryAuthoring.commitInteractiveEdit() ?? false
    }

    @discardableResult
    public func cancelTransform() -> Bool {
        guard transformVertices != nil else { return false }
        transformVertices = nil
        EditorGizmoController.shared.clearDrag()
        pointer.clear()
        _ = app?.geometryAuthoring.cancelInteractiveEdit()
        return true
    }

    func rememberTopology(_ mesh: PolygonMesh) { topology = mesh.faces.map(\.vertices); vertexCount = mesh.positions.count }
    func refresh() { app?.store.geometryChanged(); app?.requestDisplayRefresh() }
}

public enum EditorMeshExtrusionDirection: String, CaseIterable, Sendable { case normal, x, y, z }

public final class EditorMeshPointerSession {
    public var start: SIMD2<Float>?
    public var current: SIMD2<Float>?
    public var modifiers: KeyModifiers = []
    public var marquee: UIRect?
    public var gizmoStart: simd_float4x4?
    public var objectWorld: simd_float4x4?
    public func clear() { start = nil; current = nil; marquee = nil; gizmoStart = nil; objectWorld = nil; modifiers = [] }
}
