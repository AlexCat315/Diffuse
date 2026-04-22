import GuavaUIRuntime
import RHIWGPU

/// 启动一个 GuavaUI 应用窗口时所需的最小参数。所有字段都有默认值，
/// 调用方通常只需要传 `title` 加 root view。
public struct AppConfig: Sendable {
    /// 窗口标题。
    public var title: String
    /// 主字体名称。会用于 `TextEnvironment.bootstrapped`。
    public var primaryFontName: String
    /// 默认字号。
    public var defaultFontSize: Float
    /// 默认行高。
    public var defaultLineHeight: Float
    /// 清屏颜色（默认接近 `Theme.defaultDark` 的 background）。
    public var clearColor: GPUColor
    /// wgpu 后端配置。
    public var backendConfig: WGPUDeviceConfig

    public init(title: String = "GuavaUI",
                primaryFontName: String = "Helvetica Neue",
                defaultFontSize: Float = 13,
                defaultLineHeight: Float = 16,
                clearColor: GPUColor = GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1),
                backendConfig: WGPUDeviceConfig = WGPUDeviceConfig()) {
        self.title = title
        self.primaryFontName = primaryFontName
        self.defaultFontSize = defaultFontSize
        self.defaultLineHeight = defaultLineHeight
        self.clearColor = clearColor
        self.backendConfig = backendConfig
    }
}
