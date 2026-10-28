import NativeRHI

struct NativeEditorPasses {
    let grid: NativeEditorGridPass
    let geometry: NativeGeometryOverlayPass
    init(device: Device) throws {
        grid = try NativeEditorGridPass(device: device)
        geometry = try NativeGeometryOverlayPass(device: device)
    }
}
