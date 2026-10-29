import AssetPipeline

struct EditorLoopCutState {
    var seed: PolygonMeshEdge?
    var originalSelection: Set<Int> = []
    var count = 1
    var slide: Float = 0
    var valid = false
}

extension EditorMeshEditing {
    public var isLoopCutting: Bool { loopCut.seed != nil }
    public var loopCutCount: Int { loopCut.count }
    public var loopCutSlide: Float { loopCut.slide }
    public var isLoopCutPreviewValid: Bool { loopCut.valid }

    @discardableResult
    public func beginLoopCut() -> Bool {
        synchronize()
        guard !hasInteractiveEdit,pointer.start == nil,mode == .edge,selection.count == 1,
              let index = selection.first,let picker = picker(),picker.edges.indices.contains(index),
              let id = entityID,let app,app.geometryAuthoring.beginInteractiveEdit(entityID: id) else { return false }
        loopCut = .init(seed: picker.edges[index],originalSelection: selection)
        if previewLoopCut(cuts: 1,slide: 0) { return true }
        _ = cancelLoopCut()
        app.logConsole("Loop cut requires a consistent strip of convex planar quads with affine UVs",severity: .error)
        return false
    }

    @discardableResult
    public func previewLoopCut(cuts: Int,slide: Float) -> Bool {
        guard let seed = loopCut.seed,let app else { return false }
        loopCut.count = cuts; loopCut.slide = slide
        var selected = Set<PolygonMeshEdge>()
        loopCut.valid = app.geometryAuthoring.previewInteractiveEdit { document in
            guard case var .polygon(mesh) = document.source else { throw GeometryError.invalidParameter("loop cut source") }
            selected = try mesh.loopCut(startingAt: seed,cuts: cuts,slide: slide)
            document.source = .polygon(mesh: mesh)
        }
        if loopCut.valid,let mesh = controlMesh() {
            selection = Set(mesh.edges.enumerated().filter { selected.contains($0.element) }.map(\.offset))
        }
        refresh()
        return loopCut.valid
    }

    @discardableResult
    public func commitLoopCut() -> Bool {
        guard isLoopCutting,loopCut.valid,let app else { return false }
        loopCut.seed = nil; loopCut.valid = false
        let success = app.geometryAuthoring.commitInteractiveEdit()
        if success,let mesh = controlMesh() { rememberTopology(mesh) }
        else { selection = loopCut.originalSelection; synchronize() }
        refresh()
        return success
    }

    @discardableResult
    public func cancelLoopCut() -> Bool {
        guard isLoopCutting else { return false }
        loopCut.seed = nil; loopCut.valid = false
        _ = app?.geometryAuthoring.cancelInteractiveEdit()
        selection = loopCut.originalSelection
        synchronize(); refresh()
        return true
    }
}
