import NativeRHI
import RHIWGPU

/// GPU device selected by an EngineHost render session.
///
/// WGPU remains the default while NativeRHI can be injected into the same
/// render-thread pipeline for staged scene migration. A NativeRHI Device is
/// owned by the application so the UI compositor can share it safely.
public enum EngineRenderDevice: @unchecked Sendable {
    case wgpu(WGPUBackend)
    case native(Device)

    public var wgpuBackend: WGPUBackend? {
        guard case .wgpu(let backend) = self else { return nil }
        return backend
    }

    public var nativeDevice: Device? {
        guard case .native(let device) = self else { return nil }
        return device
    }
}
