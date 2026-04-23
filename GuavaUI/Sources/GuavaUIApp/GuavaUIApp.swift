/// GuavaUIApp — 高层应用宿主层
///
/// 把 GuavaUIRuntime（窗口、节点树、文本、wgpu 渲染）和 GuavaUICompose（声明式 View）
/// 装配在一起，对调用方暴露 `AppRuntime.run(...)` 一行启动入口。
/// 业务侧（Editor、Demo、第三方 App）只编写 `View` 与 `PanelWorkspace`，
/// 不再关心 `SDL3PlatformHost`、`WGPUBackend`、`DrawListRenderer`、`TextEnvironment`
/// 这些底层装配。
public enum GuavaUIApp {
    public static let version = "0.1.0"
}
