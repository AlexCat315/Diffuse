import AssetPipeline

extension EditorMeshEditing {
    @discardableResult
    public func beginInset() -> Bool {
        synchronize()
        guard !hasInteractiveEdit, pointer.start == nil, mode == .face, !selection.isEmpty,
              let app, let id = entityID, let mesh = controlMesh() else { return false }
        do {
            let width = try mesh.suggestedInsetDistance(faces: selection)
            guard app.geometryAuthoring.beginInteractiveEdit(entityID: id) else { return false }
            insetFaces = selection
            if previewInset(distance: width) { return true }
            _ = cancelInset()
        } catch { app.logConsole("Inset requires convex planar faces with affine UVs",severity: .error,detail: String(describing: error)) }
        return false
    }

    @discardableResult
    public func previewInset(distance: Float) -> Bool {
        guard let faces = insetFaces, let app else { return false }
        insetDistance = distance
        isInsetPreviewValid = app.geometryAuthoring.previewInteractiveEdit { document in
            guard case var .polygon(mesh) = document.source else { throw GeometryError.invalidParameter("inset source") }
            try mesh.inset(faces: faces,by: distance)
            document.source = .polygon(mesh: mesh)
        }
        refresh()
        return isInsetPreviewValid
    }

    @discardableResult
    public func commitInset() -> Bool {
        guard isInsetting, isInsetPreviewValid, let app else { return false }
        insetFaces = nil; isInsetPreviewValid = false
        let success = app.geometryAuthoring.commitInteractiveEdit()
        if success, let mesh = controlMesh() { rememberTopology(mesh) }
        else { synchronize() }
        refresh()
        return success
    }

    @discardableResult
    public func cancelInset() -> Bool {
        guard isInsetting else { return false }
        insetFaces = nil; isInsetPreviewValid = false
        _ = app?.geometryAuthoring.cancelInteractiveEdit()
        synchronize()
        refresh()
        return true
    }

    @discardableResult
    public func cancelInteractiveEdit() -> Bool { isInsetting ? cancelInset() : cancelTransform() }

    @discardableResult
    public func commitInteractiveEdit() -> Bool { isInsetting ? commitInset() : finishTransform() }
}
