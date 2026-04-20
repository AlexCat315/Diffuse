# GuavaUI 框架蓝图（wgpu 自渲染，跨平台）

## 0. 决策摘要

| 项目 | 选型 | 理由 |
|------|------|------|
| 渲染后端 | wgpu | 与引擎共享同一 Device，零拷贝视口，跨平台（Metal/Vulkan/DX12） |
| 布局引擎 | Yoga（C，MIT） | Facebook 成熟 flexbox 实现，支持 flex-grow/wrap/min-max，C ABI 直接包装 |
| 文字 shaping | HarfBuzz + FreeType（C） | 跨平台统一字形排版，macOS 可选 CoreText 加速首版 |
| 窗口/输入 | SDL3（C，zlib） | 跨平台窗口创建与输入事件，稳定且轻量 |
| UI 范式 | Retained mode | 样式/布局与渲染帧解耦，dirty flag 优化，Widget 可持有内部状态 |
| 主语言 | Swift | 与引擎统一，ARC 内存管理，表达力强 |

## 1. 模块结构

```
Sources/GuavaUI/
├── Core/
│   ├── ViewTree.swift           // retained-mode 节点树
│   ├── ViewNode.swift           // 节点基类：bounds、style、children、dirty flag
│   ├── StyleSystem.swift        // 主题定义：颜色、间距、圆角、字体
│   ├── Theme.swift              // 内置主题（dark/light）与自定义主题接口
│   └── HitTest.swift            // 坐标 → 节点映射
├── Event/
│   ├── EventTypes.swift         // MouseDown/Up/Move/Scroll/KeyDown/KeyUp/Focus/Blur
│   ├── EventDispatch.swift      // 捕获 → 目标 → 冒泡
│   ├── FocusManager.swift       // Tab 焦点链、焦点环
│   └── SDLEventAdapter.swift    // SDL3 事件 → GuavaUI 事件转换
├── Layout/
│   ├── YogaLayout.swift         // Yoga C API 的 Swift 封装
│   ├── LayoutNode.swift         // ViewNode 与 YGNodeRef 的映射
│   └── LayoutCache.swift        // 布局结果缓存与 dirty 传播
├── Render/
│   ├── UIRenderer.swift         // wgpu 2D 批处理渲染器总控
│   ├── PrimitiveRenderer.swift  // 填充/圆角矩形、边框、阴影（SDF shader）
│   ├── TextRenderer.swift       // glyph atlas + 文字四边形
│   ├── ImageRenderer.swift      // 图片/纹理四边形
│   ├── GlyphAtlas.swift         // 字形纹理图集管理
│   ├── DrawList.swift           // 帧级绘制命令列表（排序、裁剪、批合并）
│   └── Shaders/
│       ├── ui_primitive.wgsl    // 圆角矩形 SDF + 边框 + 阴影
│       └── ui_text.wgsl         // 文字四边形采样
├── Widgets/
│   ├── Label.swift
│   ├── Button.swift
│   ├── TextField.swift
│   ├── Slider.swift
│   ├── Checkbox.swift
│   ├── ScrollView.swift
│   ├── TreeView.swift
│   ├── ListView.swift
│   ├── PropertyGrid.swift
│   ├── TabBar.swift
│   ├── SplitPane.swift
│   ├── ContextMenu.swift
│   ├── Tooltip.swift
│   └── ViewportWidget.swift     // 引擎 viewport 纹理采样 + 输入路由
├── Dock/
│   ├── DockModel.swift          // split/leaf 树数据模型
│   ├── DockContainer.swift      // 拖拽分割、合并、tab 移动
│   ├── DockSerializer.swift     // JSON 持久化与恢复
│   └── DockDropZone.swift       // 拖拽放置区域计算
├── Platform/
│   ├── SDLWindowBackend.swift   // SDL3 窗口 + 事件泵
│   ├── ClipboardBackend.swift   // SDL3 剪贴板封装
│   └── FileDialogBackend.swift  // 平台文件对话框（SDL3 + 平台 fallback）
└── Bridge/
    ├── CYogaBridge/             // Yoga C 头文件包装（SwiftPM C target）
    │   ├── include/yoga.h
    │   └── yoga.c (stub or link)
    ├── CTextBridge/             // HarfBuzz + FreeType C 头文件包装
    │   ├── include/text_bridge.h
    │   └── text_bridge.c
    └── CSDL3/                   // SDL3 C 头文件包装
        ├── include/sdl3.h
        └── module.modulemap
```

## 2. 渲染管线

### 2.1 图元类型

GuavaUI 只实现编辑器 UI 所需的有限图元，不实现通用矢量图形：

| 图元 | 实现方式 | 用途 |
|------|----------|------|
| 填充矩形 | 顶点着色 | 面板背景、选中高亮 |
| 圆角矩形 | SDF fragment shader | 按钮、输入框、面板边框 |
| 边框 | SDF 内/外描边 | Widget 边界 |
| 阴影 | 高斯模糊 SDF | 弹出层、浮动面板 |
| 文字四边形 | Glyph atlas 采样 | 所有文字渲染 |
| 图片四边形 | 纹理采样 | 图标、缩略图、viewport 纹理 |

### 2.2 批处理策略

1. 遍历 ViewTree，生成 DrawList（有序绘制命令列表）。
2. DrawList 按纹理/shader 分组合并，减少 draw call。
3. 裁剪：scissor rect 按面板边界裁剪，不渲染可见区域外的 Widget。
4. 所有顶点写入单个 vertex buffer，索引写入单个 index buffer。
5. 每帧 draw call 目标：< 50（典型编辑器布局）。

### 2.3 Shader 设计

ui_primitive.wgsl（圆角矩形 + 边框 + 阴影）：

```wgsl
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
    @location(3) rect: vec4<f32>,       // x, y, width, height
    @location(4) params: vec4<f32>,     // corner_radius, border_width, shadow_radius, 0
};

@fragment
fn fs_main(in: VertexInput) -> @location(0) vec4<f32> {
    let half_size = in.rect.zw * 0.5;
    let center = in.rect.xy + half_size;
    let p = in.position - center;
    let r = in.params.x;

    // SDF for rounded rectangle
    let q = abs(p) - half_size + vec2<f32>(r, r);
    let d = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;

    // 填充
    let fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

    // 边框
    let border_w = in.params.y;
    let border_alpha = 1.0 - smoothstep(-0.5, 0.5, abs(d) - border_w * 0.5);

    return in.color * fill_alpha;
}
```

### 2.4 文字渲染流程

1. 文字 shaping（HarfBuzz）：输入 Unicode 字符串 → 输出 glyph ID + 位置偏移。
2. 字形光栅化（FreeType）：glyph ID → 灰度位图。
3. 写入 GlyphAtlas：灰度位图 → wgpu 纹理图集（按需扩展）。
4. 生成四边形：每个 glyph 一个四边形，UV 指向 atlas 中的位置。
5. 渲染：ui_text.wgsl 采样 glyph atlas 纹理。

GlyphAtlas 策略：

- 初始大小 1024x1024。
- 使用 shelf packing 算法。
- LRU 淘汰不常用字形。
- 支持多号字体共存（不同 size 分开缓存）。

## 3. 布局引擎（Yoga 集成）

### 3.1 核心封装

```swift
public final class YogaLayout {
    private var nodeRef: YGNodeRef

    public init() {
        nodeRef = YGNodeNew()
    }

    deinit {
        YGNodeFree(nodeRef)
    }

    public func setFlexDirection(_ direction: FlexDirection) {
        YGNodeStyleSetFlexDirection(nodeRef, direction.yogaValue)
    }

    public func setWidth(_ value: Float) {
        YGNodeStyleSetWidth(nodeRef, value)
    }

    public func setHeight(_ value: Float) {
        YGNodeStyleSetHeight(nodeRef, value)
    }

    public func setPadding(_ edge: Edge, _ value: Float) {
        YGNodeStyleSetPadding(nodeRef, edge.yogaValue, value)
    }

    public func setMargin(_ edge: Edge, _ value: Float) {
        YGNodeStyleSetMargin(nodeRef, edge.yogaValue, value)
    }

    public func setFlexGrow(_ value: Float) {
        YGNodeStyleSetFlexGrow(nodeRef, value)
    }

    public func addChild(_ child: YogaLayout, at index: Int) {
        YGNodeInsertChild(nodeRef, child.nodeRef, UInt32(index))
    }

    public func calculateLayout(width: Float, height: Float) {
        YGNodeCalculateLayout(nodeRef, width, height, .LTR)
    }

    public var computedFrame: CGRect {
        CGRect(
            x: CGFloat(YGNodeLayoutGetLeft(nodeRef)),
            y: CGFloat(YGNodeLayoutGetTop(nodeRef)),
            width: CGFloat(YGNodeLayoutGetWidth(nodeRef)),
            height: CGFloat(YGNodeLayoutGetHeight(nodeRef)),
        )
    }
}
```

### 3.2 ViewNode 与 YogaLayout 映射

每个 ViewNode 持有一个 YogaLayout 实例。当 ViewNode 的样式属性变更时：

1. 标记 dirty flag。
2. 下一帧渲染前，从 dirty 节点向上传播到根节点。
3. 根节点调用 `calculateLayout(width: windowWidth, height: windowHeight)`。
4. 遍历树，将计算结果写入每个 ViewNode 的 `computedFrame`。
5. 只有 dirty 子树才重新计算，其余跳过。

## 4. 事件系统

### 4.1 事件流

```
SDL3 Event → SDLEventAdapter.convert() → GuavaUI Event
    → HitTest(position) → targetNode
    → Capture phase（根 → 目标，依次调用 onCapture）
    → Target phase（目标节点调用 onEvent）
    → Bubble phase（目标 → 根，依次调用 onBubble）
```

### 4.2 焦点管理

- Tab 键在可聚焦 Widget 间顺序切换。
- FocusManager 维护焦点链（有序列表）。
- 键盘事件只派发给当前焦点节点。
- ESC 键清除焦点。

### 4.3 输入路由到引擎视口

ViewportWidget 是 GuavaUI 的一个 Widget，其事件处理逻辑：

1. 鼠标/键盘事件命中 ViewportWidget 区域时，不走 GuavaUI 冒泡。
2. 转换为引擎输入格式，通过 EngineHost 命令队列发送。
3. 框选、拾取、Gizmo 操作均通过此路径。

## 5. Widget 系统

### 5.1 Widget 协议

```swift
public protocol Widget: AnyObject {
    var node: ViewNode { get }

    /// 布局属性发生变化时调用
    func applyStyle()

    /// 生成绘制命令到 DrawList
    func draw(list: inout DrawList, frame: CGRect)

    /// 处理事件，返回 true 表示已消费
    func handleEvent(_ event: UIEvent) -> Bool
}
```

### 5.2 关键 Widget 设计

**TreeView**（用于 SceneHierarchy）：

- 数据源协议：`TreeDataSource`（childCount、child(at:)、label(for:)）。
- 虚拟化滚动：只渲染可见区域内的行。
- 展开/折叠状态管理。
- 拖拽重排（reparent）。

**PropertyGrid**（用于 Inspector）：

- 键值对列表，值域支持多种编辑器（TextField、Slider、ColorPicker、Dropdown）。
- 分组与折叠。
- 数据绑定：修改后通过命令总线发回引擎。

**ViewportWidget**：

- 采样引擎输出的 wgpu 纹理。
- 输入路由到引擎。
- Gizmo overlay 渲染（可选：在引擎侧渲染，或在 GuavaUI 侧叠加）。
- 帧统计 HUD（FPS、draw calls、帧耗时）。

## 6. Docking 系统

### 6.1 数据模型

```swift
public indirect enum DockNode: Codable {
    case leaf(LeafData)
    case split(SplitData)

    public struct LeafData: Codable {
        public var tabs: [PanelId]
        public var activeTab: Int
    }

    public struct SplitData: Codable {
        public var direction: SplitDirection
        public var ratio: Float
        public var children: [DockNode]
    }
}

public enum SplitDirection: String, Codable {
    case horizontal
    case vertical
}

public typealias PanelId = String
```

### 6.2 默认编辑器布局

```
DockNode.split(
    direction: .horizontal,
    ratio: 0.2,
    children: [
        .leaf(tabs: ["sceneHierarchy"]),                    // 左侧
        .split(
            direction: .horizontal,
            ratio: 0.75,
            children: [
                .split(
                    direction: .vertical,
                    ratio: 0.7,
                    children: [
                        .leaf(tabs: ["viewport"]),          // 中心
                        .leaf(tabs: ["console", "assets", "timeline"]) // 底部
                    ]
                ),
                .leaf(tabs: ["inspector"])                  // 右侧
            ]
        )
    ]
)
```

### 6.3 拖拽操作

1. 用户拖动 tab 标签。
2. DockDropZone 计算放置位置（左/右/上/下/tab/浮动）。
3. 视觉反馈：半透明蓝色矩形指示放置区域。
4. 释放后，DockModel 执行树结构变换（移除 → 插入 → 清理空节点）。
5. 变换后重新触发 Yoga 布局计算。

### 6.4 持久化

布局保存为 JSON，存储在用户配置目录下。启动时加载，找不到则使用默认布局。

## 7. 主题系统

```swift
public struct Theme {
    // 面板
    public var panelBackground: Color
    public var panelBorder: Color
    public var panelBorderWidth: Float

    // Widget
    public var buttonBackground: Color
    public var buttonHover: Color
    public var buttonActive: Color
    public var buttonCornerRadius: Float

    // 文字
    public var textPrimary: Color
    public var textSecondary: Color
    public var textDisabled: Color
    public var fontFamily: String
    public var fontSize: Float
    public var fontSizeLarge: Float
    public var fontSizeSmall: Float

    // 间距
    public var paddingSmall: Float
    public var paddingMedium: Float
    public var paddingLarge: Float
    public var itemSpacing: Float

    // 选中与焦点
    public var selectionBackground: Color
    public var focusBorder: Color
    public var focusBorderWidth: Float

    // Dock
    public var tabBackground: Color
    public var tabActive: Color
    public var tabHover: Color
    public var splitHandleColor: Color
    public var splitHandleWidth: Float

    // Viewport
    public var viewportBorder: Color

    public static let dark = Theme(/* dark theme values */)
    public static let light = Theme(/* light theme values */)
}
```

所有 Widget 从当前 Theme 读取样式，不硬编码颜色和间距。切换主题 = 替换 Theme 实例 + 标记全树 dirty。

## 8. 跨平台策略

### 8.1 平台抽象层

| 功能 | macOS | Windows | Linux |
|------|-------|---------|-------|
| 窗口创建 | SDL3 | SDL3 | SDL3 |
| 输入事件 | SDL3 | SDL3 | SDL3 |
| wgpu 后端 | Metal | DX12 / Vulkan | Vulkan |
| 文字 shaping | HarfBuzz | HarfBuzz | HarfBuzz |
| 字形光栅化 | CoreText (首版) → FreeType | FreeType | FreeType |
| 文件对话框 | NSOpenPanel (Obj-C bridge) | Win32 GetOpenFileName | zenity / GTK dialog |
| 剪贴板 | SDL3 | SDL3 | SDL3 |
| 系统菜单 | SDL3 (3.2+) 或平台桥接 | SDL3 或 Win32 | SDL3 |

### 8.2 Swift 跨平台编译

Swift 在 macOS / Linux 上已稳定。Windows 支持持续改善（Swift 6.0+ 官方支持）。

构建命令统一：`swift build`，不依赖 Xcode。

### 8.3 平台特定代码隔离

```swift
#if os(macOS)
import AppKit
func showFileDialog() -> String? {
    // NSOpenPanel
}
#elseif os(Windows)
func showFileDialog() -> String? {
    // Win32 GetOpenFileName via C bridge
}
#elseif os(Linux)
func showFileDialog() -> String? {
    // zenity subprocess
}
#endif
```

平台特定代码集中在 `Platform/` 目录，其他所有模块不包含 `#if os()` 条件编译。

## 9. 分阶段实施

| 阶段 | 目标 | 验收 |
|------|------|------|
| UI-P0（1-2 周） | wgpu 2D 渲染器：彩色矩形 + 圆角矩形 + 文字渲染 | 在 SDL3 窗口中渲染带文字的按钮 |
| UI-P1（1-2 周） | Yoga 集成 + ViewTree + EventDispatch + Label/Button/TextField | flexbox 布局可用，按钮可点击，文字可输入 |
| UI-P2（2-3 周） | TreeView + PropertyGrid + TabBar + SplitPane + ScrollView | 能搭出 SceneHierarchy + Inspector 原型 |
| UI-P3（2-3 周） | DockContainer + 拖拽分割合并 + 布局持久化 | 拖拽面板、分割窗口、保存/恢复布局 |
| UI-P4（1-2 周） | ViewportWidget + 引擎纹理采样 + 输入路由 | viewport 区域渲染 3D 场景，鼠标交互正常 |
| UI-P5（持续） | 主题打磨、动画、滚动惯性、右键菜单、快捷键 | 编辑器可用度对标当前 Electron 版本 |

## 10. 风险与缓解

风险 1：wgpu 2D 渲染性能不足以支撑复杂编辑器 UI。

缓解：批处理 + scissor 裁剪 + dirty 区域重绘。典型编辑器 UI 的顶点量远小于 3D 场景，wgpu 处理无压力。测试目标：26 个面板全开时 UI 渲染耗时 < 1ms。

风险 2：文字渲染质量不达标（模糊、间距异常）。

缓解：HarfBuzz 做 shaping 保证排版正确，FreeType 做亚像素光栅化保证清晰度。macOS 首版可用 CoreText 对标系统字体质量。

风险 3：Yoga 布局性能在大量节点时退化。

缓解：dirty flag 机制避免全树重算。编辑器面板典型节点数 < 5000，Yoga 处理 < 0.1ms。

风险 4：跨平台文件对话框体验不一致。

缓解：各平台使用原生对话框 API，不自己画文件选择器。

风险 5：自渲染 UI 的无障碍（accessibility）支持。

缓解：首版不做无障碍支持。后续可通过平台 accessibility API 桥接（macOS NSAccessibility、Windows UIA）。

## 11. 参考实现

| 项目 | 相关度 | 参考价值 |
|------|--------|----------|
| Godot Editor | 高 | 同类方案：引擎自渲染编辑器 UI，retained mode，自带 docking |
| Zed Editor (GPUI) | 高 | GPU 加速自渲染 UI，Rust + Metal/Vulkan，高性能文字渲染 |
| egui | 中 | wgpu 后端 immediate-mode UI，可参考渲染器实现 |
| Vello | 中 | wgpu 上的 2D 矢量渲染器，可参考 SDF 和批处理策略 |
| Dear ImGui | 中 | wgpu 后端实现、docking branch 的树模型 |
