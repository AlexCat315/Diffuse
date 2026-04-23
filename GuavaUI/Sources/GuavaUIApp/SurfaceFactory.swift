import GuavaUIRuntime
import PlatformShell
import RHIWGPU

/// Builds a `GPUSurface` for a `NativeRenderSurface`. Centralised so the
/// per-platform `switch` lives in one place instead of being copy-pasted into
/// every demo / app entry point.
@MainActor
enum SurfaceFactory {
    static func make(backend: WGPUBackend, native: NativeRenderSurface) throws -> GPUSurface {
        switch native {
        case .metalLayer(let ptr):
            return try backend.createSurfaceMetal(layer: ptr)
        case .win32Window(let hwnd, let hinstance):
            return try backend.createSurfaceWin32(hwnd: hwnd, hinstance: hinstance)
        case .waylandSurface(let display, let surface):
            return try backend.createSurfaceWayland(display: display, surface: surface)
        case .xlibWindow(let display, let window):
            return try backend.createSurfaceXlib(display: display, window: window)
        }
    }
}
