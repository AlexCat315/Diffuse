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
    /// DevTools 配置。`nil` 关闭。默认从 `GUAVA_DEVTOOLS=1` env var 读取，
    /// 这样 release 构建不会意外开启服务端。
    public var devTools: DevToolsConfig?

    public init(title: String = "GuavaUI",
                primaryFontName: String = SystemFontDefaults.primaryFontName,
                defaultFontSize: Float = 13,
                defaultLineHeight: Float = 16,
                clearColor: GPUColor = GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1),
                backendConfig: WGPUDeviceConfig = WGPUDeviceConfig(),
                devTools: DevToolsConfig? = nil) {
        self.title = title
        self.primaryFontName = primaryFontName
        self.defaultFontSize = defaultFontSize
        self.defaultLineHeight = defaultLineHeight
        self.clearColor = clearColor
        self.backendConfig = backendConfig
        self.devTools = devTools ?? DevToolsConfig.fromEnvironment(appTitle: title)
    }
}
