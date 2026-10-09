import GuavaUIRuntime
import NativeRHI
import PlatformShell
import RHIWGPU

/// Builds a `GPUSurface` for a `NativeRenderSurface`. Centralised so the
/// per-platform `switch` lives in one place instead of being copy-pasted into
/// every demo / app entry point.
@MainActor
enum SurfaceFactory {
    static func nativeDescriptor(native: NativeRenderSurface, size: SIMD2<UInt32>, vsync: Bool) -> SurfaceDescriptor {
        var result: SurfaceDescriptor
        switch native {
        case .metalLayer(let pointer):
            result = SurfaceDescriptor(nativeHandle: pointer, width: Int(size.x), height: Int(size.y))
        case .win32Window(let window, _):
            result = SurfaceDescriptor(nativeHandle: window, width: Int(size.x), height: Int(size.y))
            result.kind = .win32Window
        case .waylandSurface(let display, let surface):
            result = SurfaceDescriptor(nativeHandle: surface, width: Int(size.x), height: Int(size.y))
            result.kind = .waylandSurface; result.display = display
        case .xlibWindow(let display, let window):
            result = SurfaceDescriptor(nativeHandle: UnsafeMutableRawPointer(bitPattern: UInt(window)),
                width: Int(size.x), height: Int(size.y))
            result.kind = .xlibWindow; result.display = display
        }
        result.colorFormat = .bgra8UnormSRGB
        result.vsyncEnabled = vsync
        return result
    }

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
