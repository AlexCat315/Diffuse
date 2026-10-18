# WebView

`GuavaUIWebView` 把**平台原生网页视图**放进 Compose 树：布局、裁剪、可见性和生命周期由 GuavaUI 拥有，页面本身由 WebKit / WebView2 / WebKitGTK / Android WebView 渲染。它不是 HTML 渲染器，也不把网页画进 DrawList。

当前仓库已实现 macOS 的 `WKWebView` 后端；其他平台需要应用或宿主提供 `WebViewHost`。Demo 的 `web` 页在非 macOS 平台显示明确的后端缺失提示。

## API

```swift
import AppKit
import Foundation
import GuavaUI
import GuavaUIWebView

@State private var browser = WebViewHandle()
@State private var state = WebViewState()
@State private var host: AppleWebKitHost

init() {
    _host = State(wrappedValue: AppleWebKitHost { NSApp.mainWindow })
}

var body: some View {
    WebView(
        .url(URL(string: "https://example.com")!),
        host: host,
        handle: browser
    ) { state = $0 }
    .frame(height: 460)
}
```

- `WebViewRequest` 为 `.url(URL)` 或 `.html(String, baseURL: URL?)`。相同 request 不会重复加载。
- `WebViewState` 由宿主发布：`phase`、`url`、`title`、`canGoBack`、`canGoForward`、`errorDescription`。
- `host` 是 surface 的身份键。必须在 `@State` 或应用 session 中只创建一次，不要在 body 内联 `AppleWebKitHost { ... }`；否则每次重组都会拆掉并重建浏览器视图。
- `WebViewHandle` 提供 `goBack()`、`goForward()`、`reload()`、`stopLoading()`、`load(_:)`。句柄不是 observable；导航状态以 `WebViewState` 为唯一来源。
- 调用方必须给 `WebView` 一个尺寸（`.frame` 或父级 flex）。默认布局节点 `flexGrow = 1`，不提供固有宽高。

## 宿主边界

网页视图由 `WebViewHost` 创建，GuavaUI 不依赖具体浏览器框架：

```swift
public protocol WebViewHost: AnyObject {
    @MainActor func makeSurface() -> any WebViewSurface
}

public protocol WebViewSurface: AnyObject {
    @MainActor var onStateChange: ((WebViewState) -> Void)? { get set }
    @MainActor func load(_ request: WebViewRequest)
    @MainActor func perform(_ command: WebViewCommand)
    @MainActor func updateGeometry(_ geometry: WebViewGeometry)
    @MainActor func detach()
}
```

`WebViewGeometry` 同时给全量 `frame` 和裁剪后的 `visibleFrame`。宿主应把原生视图放进一个按 `visibleFrame` 裁切的容器，并把 `frame` 相对容器左上角摆放；`isVisible == false` 时必须隐藏原生视图。`updateGeometry` 会在布局和绘制时调用，因此滚动、窗口缩放和父级隐藏都会同步。

macOS 的 `AppleWebKitHost` 只负责创建 `WKWebView`；窗口来自调用方的 provider，所以主窗口、辅助窗口和测试宿主可以共用同一个 Composed 页面。

其他平台的适配点：

| 平台 | 原生视图 | 备注 |
| --- | --- | --- |
| iOS | `WKWebView` + `UIWindow` | 可复用 macOS 的 WebKit 经验；当前仓库 iOS 应用宿主尚未完成，本产品尚未提供 iOS host |
| Windows | WebView2 (`ICoreWebView2Controller`) | 需要一个子 HWND/窗口 controller |
| Linux | WebKitGTK | 需要 GTK 主循环与 X11/Wayland surface |
| Android | `android.webkit.WebView` | 放进宿主 `FrameLayout`；需要 JNI 传递 frame/可见性 |
| Browser/Wasm | `iframe` | 仅浏览器宿主；DOM 覆盖层不参与 Canvas DrawList |

## 生命周期与裁剪

- `WebView` 在 `NodeResource` 中持有 surface；节点离开树时调用 `detach()`，页面、KVO 和容器一起释放。
- 裁剪来自实际绘制祖先的 `clipsToBounds` 交集。原生视图只显示交集部分；滚出视口时隐藏，不会盖住工具栏或侧栏。
- 节点隐藏（`isLayoutVisible == false`）时布局钩子仍会报告 `.hidden`，不会留下“幽灵”原生视图。
- 原生视图追加到 `window.contentView` 的最上层；它不能在 GuavaUI 的 z-order 中插入。需要盖住网页的菜单、弹层、Toast 必须放在网页矩形之外，或先卸载网页。
- 圆角、透明度、缩放/变换、边框混合不会被原生视图继承。不要在 WebView 上依赖这些视觉效果。
- 网页的字体、配色和文字缩放由页面 CSS / WebKit 决定，不跟随 GuavaUI 的 `Theme` 或 `TextScaler`。
- 网页不能进入 DevTools 的 DrawList 镜像、Pick 或截图。它也尚未并入 GuavaUI 的 `MacAccessibilityBridge`；原生 WebView 的读屏可达性未做验收，需要宿主自行接入。
- 原生视图与 Compose 输入焦点不自动同步：点击网页后键盘焦点在 WebView 内，点击回 GuavaUI 文本字段时由该控件重新请求焦点。复杂表单混排需要宿主额外处理焦点切换。

## macOS 事项

- 窗口 provider 返回 `nil` 时页面不会挂载；窗口变化会在下一次 geometry 更新时重新附加。
- `loadHTMLString` 的初始文档是否进入 WebKit 历史栈由 WebKit 决定，因此 Back/Forward 以 `canGoBack`/`canGoForward` 的实际值为准；不要假设本地 HTML 一定可后退。
- 沙盒应用如访问网络，需要在 entitlements 中声明 `com.apple.security.network.client`。`WKWebView` 的进程外网页内容仍受系统网络策略约束。
- 原生视图是 `NSView` 子视图；窗口标题栏、最小化和关闭由 AppKit 处理。窗口坐标按 content view 的 flipped 状态转换。

## 验证

```sh
swift test --package-path GuavaUI --filter GuavaUIWebViewTests
swift run --package-path GuavaUI/Examples GuavaUIDemo --component web
```

`WebViewGeometryTests` 覆盖无裁剪、裁剪交集、滚出视口、隐藏祖先、零尺寸和 request/state 值语义；`WebViewLifecycleTests` 覆盖挂载加载、布局几何、同 request 不重载、request 变化、卸载 detach 和 handle 绑定。Demo 的 `web` 页提供离线 HTML、`example.com` 和仓库页面三个样例，以及 Back/Forward/Reload/Stop 和加载状态。DevTools 查询可复核 `Native web content` 与 `GuavaUI WebView` 状态文本；原生网页本身不会出现在 DrawList 镜像或截图里。

## 后续

按平台补齐 host 时，保持 `WebView`/`WebViewState`/`WebViewGeometry` 不变，只为该平台增加 `WebViewHost` 和 `WebViewSurface` 实现。不要在每个页面里直接持有 `NSView`/`HWND`/`jobject`，否则裁剪、释放和窗口切换会重新变成应用层责任。
