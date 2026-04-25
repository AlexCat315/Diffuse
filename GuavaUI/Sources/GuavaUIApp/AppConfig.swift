import GuavaUIRuntime
import GuavaUIDevTools
import RHIWGPU

/// 启动一个 GuavaUI 应用窗口时所需的最小参数。所有字段都有默认值，
/// 调用方通常只需要传 `title` 加 root view。
public struct AppConfig: Sendable {
    /// 窗口标题。
    public var title: String
    /// 主字体名称。默认使用当前平台的系统 UI 字体。
    public var primaryFontName: String
    /// 默认字号。
    public var defaultFontSize: Float
    /// 默认行高。
    public var defaultLineHeight: Float
    /// 清屏颜色（默认接近 `Theme.defaultDark` 的 background）。
    public var clearColor: GPUColor
    /// wgpu 后端配置。
    public var backendConfig: WGPUDeviceConfig
    /// UI 渲染 MSAA 采样数。1 表示关闭，常用值是 4。
    public var msaaSampleCount: UInt32
    /// Optional UI frame-rate cap. `nil` preserves the event-driven default.
    public var targetFrameRate: Double?
    /// DevTools 配置。`nil` 关闭。默认从 `GUAVA_DEVTOOLS=1` env var 读取，
    /// 这样 release 构建不会意外开启服务端。
    public var devTools: DevToolsConfig?

    public init(title: String = "GuavaUI",
                primaryFontName: String = "Inter",
                defaultFontSize: Float = 14,
                defaultLineHeight: Float = 20,
                clearColor: GPUColor = GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1),
                backendConfig: WGPUDeviceConfig = WGPUDeviceConfig(),
                msaaSampleCount: UInt32 = 4,
                targetFrameRate: Double? = nil,
                devTools: DevToolsConfig? = nil) {
        self.title = title
        self.primaryFontName = primaryFontName
        self.defaultFontSize = defaultFontSize
        self.defaultLineHeight = defaultLineHeight
        self.clearColor = clearColor
        self.backendConfig = backendConfig
        self.msaaSampleCount = max(1, msaaSampleCount)
        if let targetFrameRate, targetFrameRate.isFinite, targetFrameRate > 0 {
            self.targetFrameRate = max(1.0, min(240.0, targetFrameRate))
        } else {
            self.targetFrameRate = nil
        }
        self.devTools = devTools ?? DevToolsConfig.fromEnvironment(appTitle: title)
    }
}
