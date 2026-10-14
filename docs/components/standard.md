# GuavaUI 跨设备组件标准

GuavaUI 面向应用表面，不以桌面窗口作为组件的前提。桌面、手机、平板、嵌入式 viewport 和浏览器共享语义、状态、布局与输入模型；SDL、UIKit、Android 和浏览器适配器负责平台能力。

## 层次与依赖

| 层 | 责任 | 允许依赖 |
| --- | --- | --- |
| Portable/Core | 普通值、绘制数据、UIEnvironment | 无窗口、GPU、设备或场景 |
| Portable/Scene + ComposeCore | 节点、布局、状态、语义、输入、SurfaceReader | Core、Yoga |
| Compose | Action/Input/Navigation/Data/Feedback/Media 组件、主题 | Portable、Runtime 服务 |
| Workspace | 面板、文档区、停靠与紧凑导航 | Compose |
| Host | 生命周期、安全区、IME、缩放、输入设备、GPU 提交 | 平台适配器 |

调用方传入值、Binding 和动作闭包；组件不要求业务对象继承基类、全局注册或实现无关协议。现有 AccessibilitySemantics 是唯一语义来源，避免为 Agent 或 Inspector 再维护一套角色字段。

## SurfaceEnvironment

`UIEnvironment` 分组保存 viewport、safeArea、input 和减少动画偏好。它是瞬时宿主状态，不写入工程文件。宽度小于 600 为 compact，600–999 为 medium，1000 起为 expanded；宽度和输入设备独立，例如平板接键盘仍保留触摸能力。

```swift
SurfaceReader { surface in
    if surface.viewport.widthClass == .compact { CompactContent() }
    else { ExpandedContent() }
}
```

Application 在初始化/缩放/调整尺寸时提供环境，AndroidContentSession 在 prepare 时提供环境。iOS 从 SDL 获取安全区并在根内容应用边距。WorkspaceView 自动选择紧凑面板导航，停靠/浮动属于 expanded 呈现。宿主环境可通过 `.surfaceEnvironment` 在预览或独立表面覆盖。

## 所有组件的交付要求

- 用语义动作表达 activate、select、edit、dismiss；不让业务代码识别鼠标按钮或 SDL 常量。
- hover 是可选反馈；触摸设备必须能直接完成动作。默认触摸操作区至少 44 logical points，普通指针操作区为 28，桌面工具栏可显式使用 mini 密度。ButtonHost 从 SurfaceEnvironment 获取尺寸。
- 同一动作提供键盘、指针、触摸和辅助功能入口；焦点环区分键盘焦点与点击焦点；disabled/loading 不能误触发动作。
- 文本输入交给宿主的 IME/剪贴板和已有 TextInputClient，使用 Unicode、逻辑 start/end 和文本缩放。
- 布局使用可用空间；安全区由宿主根应用一次，独立嵌入表面自行提供环境。工具栏和导航在 compact 模式收敛，不缩小触摸目标。
- 主题保持语义颜色、字体、间距、圆角和状态 token；减少动画由环境提供，不依赖平台判断散落在组件内。
- 媒体组件接收 owned bitmap、视频帧或纹理值；解码、设备、播放时钟和导出任务留在媒体服务。
- 数据模型只保存 authored 内容；焦点、hover、IME preedit、播放进度、纹理和拖动过程属于 session。

新组件应加入相应责任目录，以真实的交互或状态测试证明其契约。当前 Button、SurfaceReader、WorkspaceView 已接入；其他已有控件的触摸密度、弹出层和宿主辅助功能能力仍需逐项迁移，不能把有一个移动 target 等同于全部控件已适配。
