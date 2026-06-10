# GuavaKit 迁移差距分析

生成日期：2026-06-07 | 范围：所有 `import GuavaUICompose` 的源文件（非测试）

## 概览

- **总文件数**：33 个源文件 + 11 个 GuavaUI 源文件 = 44 个非测试文件使用 GuavaUICompose
- **GuavaKit 已有组件**：15 个 primitive/view + 8 个 modifier
- **需要新增/补充**：约 30+ 个组件/系统

---

## A. GuavaKit 已有（API 可映射）

| GuavaUICompose | GuavaKit 等价 | 迁移难度 |
|---|---|---|
| `View` protocol | `GuavaKit.View` ✅ | 简单改名 |
| `@ViewBuilder` | `@GuavaKit.ViewBuilder` ✅ | 简单改名 |
| `AnyView` | `GuavaKit.AnyView` ✅ | 简单改名 |
| `EmptyView` | `GuavaKit.EmptyView` ✅ | 直接 |
| `Row` / `Column` | `GuavaKit.Stack(.row)` / `Stack(.column)` ✅ | 语法差异 |
| `Box(direction:)` | `GuavaKit.Stack(direction)` ✅ | 语法差异 |
| `Text` | `GuavaKit.Text` ✅ | API 差异（见下） |
| `Button` | `GuavaKit.Button` ✅ | API 差异 |
| `Spacer` | `GuavaKit.Spacer` ✅ | 直接 |
| `Divider` | `GuavaKit.Divider` ✅ | 直接 |
| `ScrollView` | `GuavaKit.ScrollView` ✅ | 直接 |
| `Toggle` | `GuavaKit.Toggle` ✅ | 功能精简 |
| `Slider` | `GuavaKit.Slider` ✅ | 功能精简 |
| `TextField` | `GuavaKit.TextField` ✅ | 功能精简 |
| `Image` | `GuavaKit.Image` ✅ | placeholder |
| `.frame(width:height:)` | `GuavaKit.frame()` ✅ | 直接 |
| `.background(color)` | `.background(color)` ✅ | 直接 |
| `.padding()` | `.padding()` ✅ | 直接 |
| `.foregroundColor()` | `.foregroundColor()` ✅ | 直接 |
| `.cornerRadius()` | `.cornerRadius()` ✅ | 直接 |
| `.clipped()` | `.clipped()` ✅ | 直接 |
| `.fontSize()` | `.fontSize()` ✅ | 直接 |
| `Color` | `GuavaKit.Color` ✅ | 直接 |
| `@State` | `@GuavaKit.State` ✅ | 简单改名 |
| `PortalHost` | `GuavaKit.PortalStore` ✅ | 架构不同 |

---

## B. 缺失 —— 核心 Primitive 组件

按使用频率排序：

| 组件 | 使用文件数 | 复杂度 | 说明 |
|---|---|---|---|
| `.font(.caption/.body/.label/.mono)` | ~15 | 中 | 需要 FontStyle enum + Typography |
| `.lineLimit()` | ~8 | 低 | 简单 modifier |
| `.flex(grow, shrink)` | ~12 | 中 | 需要 flex grow/shrink 参数 |
| `.border(color, width)` | ~3 | 低 | 简单 modifier |
| `.buttonStyle(.primary/.ghost)` | ~4 | 高 | 需要完整的 ButtonStyle 系统 |
| `PaddingModifier(horizontal:vertical:)` | ~6 | 低 | 扩展 Edges API |
| `FrameModifier(minWidth/maxWidth)` | ~2 | 中 | 扩展 frame API |
| **NumberField** | 3 | 中 | 数字输入 + 验证 |
| **Vec3Field** | 1 | 中 | 三通道向量输入 |
| **ColorField** | 1 | 高 | 颜色选择器 |
| **JsonField** | 1 | 中 | JSON 编辑器 |
| **Select** | 4 | 高 | 下拉选择，含 Popover |
| **List** | 2 | 中 | 列表容器 |
| **Tree** | 2 | 高 | 树形控件 + TreeRowStyle |
| **TabView** | 2 | 中 | 标签页容器 |
| **SplitView** | 2 | 高 | 可拖拽分割面板 |
| **Panel** | 5 | 高 | 可折叠面板 + PanelStyle |
| **PropertyGrid** | 3 | 高 | 属性网格（Inspector 核心） |
| **AssetDropTarget** | 1 | 中 | 拖放目标区域 |
| **Popover** | 5 | 高 | 弹出层 + Menu 系统 |
| **Menu** / **MenuDescriptor** | 4 | 高 | 右键菜单/下拉菜单 |
| **OverlayHost** | 1 | 中 | overlay 管理系统 |
| **ViewportHost** | 6 | 高 | 3D 视口宿主 |
| **ShortcutHost** | 1 | 中 | 键盘快捷键 |
| **LayerRoot** | 3 | 高 | 分层渲染根节点 |
| **TextFieldHost** | 0（间接） | 高 | 原生文本输入桥接 |
| **AssetRefField** | 0（间接） | 中 | 资产引用字段 |

---

## C. 缺失 —— Theme 系统

| 组件 | 使用文件数 | 复杂度 | 说明 |
|---|---|---|---|
| `SemanticColorRef` (`.success`, `.warning`, `.error`, `.surfaceSunken`, `.onSurfaceVariant`, `.onSurfaceMuted`, `.accent`, `.surfaceVariant`) | ~12 | 高 | 语义颜色系统 |
| `Theme` / `DefaultDarkTheme` | 2 | 高 | 主题引擎 |
| `Typography` + `FontStyle` (`.caption`, `.body`, `.bodyStrong`, `.label`, `.mono`) | ~15 | 中 | 排版系统 |
| `ButtonStyle` (`.primary`, `.ghost`) | 4 | 中 | 按钮样式 |
| `PanelStyle` | 1 | 中 | 面板样式 |
| `TextFieldStyle` | 1 | 中 | 输入框样式 |
| `SliderStyle` | 1 | 低 | 滑块样式 |
| `DividerStyle` | 0 | 低 | 分割线样式 |
| `InputAppearance` | 0 | 低 | 输入外观 |

---

## D. 缺失 —— 动画系统

| 组件 | 使用文件数 | 复杂度 | 说明 |
|---|---|---|---|
| `WithAnimation` | 测试 | 高 | 动画包装器 |
| `AnimationValueModifier` | 测试 | 高 | 值动画 modifier |

---

## E. 缺失 —— 状态 / Observable 桥接

| 组件 | 使用文件数 | 复杂度 | 说明 |
|---|---|---|---|
| `Observed<>` | 3 | 中 | KVO-style 可观察包装（InGameBattleHUD, EditorLaunchContext, ConfirmationHostPanel） |
| `StoreScope` | ~12 | 高 | EditorCore store → View 桥接 |

---

## F. 缺失 —— Workspace 系统（GuavaUIWorkspace）

| 组件 | 复杂度 | 说明 |
|---|---|---|
| `WorkspaceController` | 高 | 面板布局管理器（dock 系统） |
| `WorkspaceView` | 高 | 工作区渲染器 |
| `WorkspaceModel` | 中 | 数据模型 |
| `WorkspaceTheme` | 低 | 工作区主题 |
| `PanelDescriptor` | 中 | 面板注册描述符 |
| `PanelRegistry` | 中 | 面板注册表 |
| `PanelWorkspace` | 中 | 面板工作区 Composable |

---

## G. 缺失 —— App Runtime（GuavaUIApp）

| 组件 | 复杂度 | 说明 |
|---|---|---|
| `AppRuntime` | 高 | 主事件循环 + 窗口管理 |
| `WindowChrome` | 高 | 窗口标题栏 + 装饰 |
| `AppDisplayHandle` | 中 | 显示器句柄 |
| `AppConfig` | 低 | 应用配置 |
| `InGameUIHost` | 中 | 游戏内 UI 宿主 |
| `InGameViewGraphBridge` | 中 | ViewGraph 桥接 |

当前 GuavaKit 替代方案：`GuavaKitHostApp`（SDL3 + wgpu 直接驱动），功能较简单。

---

## H. 缺失 —— Modifier 糖

| Modifier | 说明 |
|---|---|
| `EdgeInsets` (`.all()`, `.horizontal()`, `.vertical()`) | GuavaKit 有 `Edges`，需扩展 API |
| `.frame(width:height:, minWidth:, maxWidth:, minHeight:, maxHeight:)` | 需扩展 frame modifier |
| `.flex(grow:, shrink:)` | 需新建 FlexModifier |
| `.border(color:, width:)` | 需新建 BorderModifier |
| `.lineLimit(_:)` | 需新建 LineLimitModifier |
| `.onTapGesture {}` | 需 pointer 事件桥接 |
| `.onHover {}` | 需 pointer 事件桥接 |
| `.debugName()` | `UINode` 已有 name 字段 |

---

## 迁移顺序建议

### 第一批：Modifier 补全（1-2 小时）
B 类低复杂度项：`.lineLimit()`、`.flex()`、`.border()`、`Edges` API 扩展、扩展 `FrameModifier`

### 第二批：Theme 基础（2-3 小时）
`SemanticColor`/`SemanticColorRef`、`FontStyle`/`Typography`、`.font()` modifier
→ 几乎所有文件都依赖这些，必须先做

### 第三批：简单面板迁移（2-3 小时）
从最简单、依赖最少的开始：
1. **StatusBar** — 最简单（~90 行）
2. **ConsolePanel** — 简单（~100 行）
3. **RenderPipelinePanel** — 中等依赖

### 第四批：中复杂度组件 + 面板（4-6 小时）
- `Select`（下拉）、`List`、`NumberField`
- **SettingsPanel**、**IntentInputPanel**、**CommandPaletteOverlay**、**ConfirmationHostPanel**

### 第五批：高复杂度系统（6-10 小时）
- `Tree`、`TabView`、`SplitView`、`Panel`、`PropertyGrid`
- **HierarchyPanel**、**InspectorPanel**、**AssetBrowserPanel**
- `Popover`/`Menu` 系统

### 第六批：核心基础设施（8-12 小时）
- `ViewportHost`（3D 视口）
- `WorkspaceController`/`WorkspaceView`（dock 布局）
- `StoreScope` 桥接
- **RootView**、**ViewportPanel**、**WelcomeView**

### 第七批：收尾（4-6 小时）
- `InGameBattleHUDView`
- **GuavaUIDemo**
- **EditorLaunchRoot**
- 动画系统（`WithAnimation`）
- 清理 GuavaUICompose 源码

---

## 风险点

1. **ViewportHost**（最高风险）— 3D 视口直接嵌入 UI 树，涉及 wgpu surface / drawable 管理，与 GuavaKitHost 的 SDL 管线耦合深
2. **WorkspaceController** — dock 布局系统非常复杂（拖拽拆分、面板标签页、布局序列化），GuavaUIWorkspace 有 ~2000 行代码
3. **Observed<>** — 被多个文件使用，与 EditorCore 的 Store 系统耦合
4. **AppRuntime** — 主事件循环，当前 GuavaKit 版本（GuavaKitHostApp）功能远不如 AppRuntime
