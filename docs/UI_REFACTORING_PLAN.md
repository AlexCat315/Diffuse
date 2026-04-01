# UI 重构计划：Unreal Editor 风格

> 状态：待执行 | 技术路线：Dear ImGui 风格改造 | 预估周期：15-20 天

## 概述

将 Guava Engine 编辑器 UI 从现有风格全面改造为 Unreal Editor 风格，覆盖视觉主题、布局结构、交互体验三个维度。保持 Dear ImGui 作为底层 UI 框架，所有改动集中在 Zig 代码层。

---

## 当前架构

### 技术栈

```
Dear ImGui (C++)
  → C Bridge (imgui_bridge.cpp)
    → Zig Bindings (src/engine/ui/imgui.zig)
      → Editor Abstraction (src/editor/ui/gui.zig)  ← 所有编辑器代码只导入这一层
        → 各 Panel 实现
```

### 关键文件结构

| 层级 | 文件 | 行数 | 作用 |
|------|------|------|------|
| 抽象层 | `src/editor/ui/gui.zig` | 246 | 统一 UI API 入口，换后端只需改一行 import |
| 主题 | `src/editor/ui/theme.zig` | 165 | 颜色、间距、尺寸集中管理 |
| 图标 | `src/editor/ui/icons.zig` + `icon_cache.zig` | — | SVG 图标路径注册 + GPU 纹理缓存 |
| 布局 | `src/editor/ui/layout.zig` | 270 | Dock 布局保存/加载/重置 |
| 主面板 | `src/editor/ui/viewport.zig` | ~2500 | 3D 视口 + 所有面板调度 |
| 菜单栏 | `src/editor/ui/menu_bar.zig` | 390 | 顶部菜单 + 窗口控制 |
| 工具栏 | `src/editor/ui/toolbar.zig` | 96 | 播放控制 |
| 场景层级 | `src/editor/ui/panels/scene/scene_hierarchy.zig` | 1095 | 场景树面板 |
| 检查器 | `src/editor/ui/panels/scene/inspector.zig` | 2283 | 实体属性编辑 |
| 属性行 | `src/editor/ui/components/property_row.zig` | 138 | 属性网格行组件 |
| 反射 UI | `src/editor/ui/reflection.zig` | 128 | 基于 Zig 反射的自动生成 UI |
| 状态 | `src/editor/core/state.zig` | 1101 | 所有 UI 状态集中管理 |
| i18n | `src/editor/i18n/` | — | 559 条消息，英文/中文 |

### 当前布局

```
┌─────────────────────────────────────────────────────────────┐
│  Menu Bar (File, Edit, Window...)                           │
├──────────────┬──────────────────────────┬───────────────────┤
│              │  Viewport (3D 场景)       │                   │
│  Hierarchy   │  ┌────────────────────┐  │   Inspector       │
│  (左侧)      │  │ Toolbar 条带        │  │   (右侧)          │
│              │  │ 3D 渲染图像         │  │                   │
│              │  │ 覆盖层: ViewCube等  │  │                   │
│              │  └────────────────────┘  │                   │
├──────────────┴──────────────────────────┴───────────────────┤
│  Content Browser / Console (底部标签页)                      │
└─────────────────────────────────────────────────────────────┘
```

## 阶段一：主题系统升级

### 1.1 扩展 theme.zig

将当前 165 行的简单调色板扩展为完整的主题系统：

```
src/editor/ui/theme.zig (重构)
├── ColorPalette          // UE 风格颜色系统
│   ├── 背景色组 (DockArea, Panel, MenuBar, TitleBar)
│   ├── 前景色组 (Text, TextSecondary, TextMuted)
│   ├── 交互色组 (Button, Hovered, Active, Disabled)
│   ├── 语义色组 (Success, Warning, Error, Info)
│   ├── 轴色组 (X=Red, Y=Green, Z=Blue)
│   └── 面板色组 (Viewport, Hierarchy, Inspector, ContentBrowser)
├── SpacingSystem         // 统一间距（4px 基准网格）
├── TypographySystem      // 字体系统（14px UE 默认）
├── SizingSystem          // 尺寸常量（控件高度统一 28px）
└── BorderRadiusSystem    // 圆角系统（UE 风格更方，2px）
```

### 1.2 UE 风格颜色方案

```zig
// Unreal Editor 风格暗色主题
pub const UEPalette = struct {
    // 背景 (UE 风格: 更深的蓝灰色调)
    pub const dock_area_bg: Color    = .{ 0.12, 0.13, 0.15, 1.0 };  // #1F2126
    pub const panel_bg: Color        = .{ 0.16, 0.17, 0.20, 1.0 };  // #292B33
    pub const panel_border: Color    = .{ 0.08, 0.09, 0.10, 1.0 };  // #14161A
    pub const title_bar_bg: Color    = .{ 0.19, 0.20, 0.24, 1.0 };  // #30333D
    pub const menu_bar_bg: Color     = .{ 0.15, 0.16, 0.19, 1.0 };  // #262830

    // 文本
    pub const text_primary: Color    = .{ 0.88, 0.89, 0.92, 1.0 };  // #E0E3EB
    pub const text_secondary: Color  = .{ 0.62, 0.64, 0.68, 1.0 };  // #9EA4AD
    pub const text_muted: Color      = .{ 0.42, 0.44, 0.48, 1.0 };  // #6B707A

    // 交互
    pub const button_bg: Color       = .{ 0.24, 0.25, 0.29, 1.0 };  // #3D404A
    pub const button_hovered: Color  = .{ 0.30, 0.31, 0.36, 1.0 };  // #4D4F5C
    pub const button_active: Color   = .{ 0.35, 0.36, 0.42, 1.0 };  // #595C6B
    pub const accent: Color          = .{ 0.25, 0.55, 0.90, 1.0 };  // #408CE6 (UE 蓝)

    // 选择/高亮
    pub const selection: Color       = .{ 0.20, 0.45, 0.80, 0.35 };
    pub const selection_border: Color= .{ 0.30, 0.60, 1.00, 1.0 };

    // 语义
    pub const success: Color         = .{ 0.20, 0.65, 0.35, 1.0 };
    pub const warning: Color         = .{ 0.85, 0.65, 0.15, 1.0 };
    pub const error: Color           = .{ 0.85, 0.25, 0.20, 1.0 };
};
```

### 1.3 魔法数字清理

从以下文件中提取所有硬编码值到主题系统：

| 文件 | 魔法数字数量 | 典型值 |
|------|-------------|--------|
| `viewport.zig` | ~80 | `14.0`, `4.0`, `7.0`, `5.0`, `0.38`, `72.0-92.0` |
| `inspector.zig` | ~40 | `42.0`, `116.0`, `80.0`, `0.05`, `0.38` |
| `scene_hierarchy.zig` | ~15 | `16.0`, `4.0`, `180.0` |
| `menu_bar.zig` | ~10 | `0.35`, `6.0`, `114.0`, `22.0` |
| `toolbar.zig` | ~5 | `20.0`, `28.0`, `6.0` |
| `layout.zig` | ~10 | `14.0`, `10.0`, `8.0` |
| `property_row.zig` | ~8 | `0.38`, `10.0`, `8.0`, `2.0` |

---

## 阶段二：ImGui 样式初始化

### 2.1 重写 initEditorStyle()

位置：`src/editor/core/layer.zig`

关键样式变更：

| 属性 | 当前值 | UE 风格 |
|------|--------|---------|
| 字体大小 | 13px | 14px |
| 窗口圆角 | 5.0 | 2.0 |
| 帧圆角 | 5.0 | 2.0 |
| 抓握尺寸 | 12.0 | 8.0 |
| 缩进 | 21.0 | 16.0 |
| 项目间距 | 较大 | 更紧凑 |
| 表格边框 | 不明显 | 更明显的分隔线 |
| 滚动条 | 标准 | 更细更低调 |

---

## 阶段三：布局重构

### 3.2 全局工具栏

当前工具栏是视口内的一个条带（`drawViewportToolbarStrip`），需要分离为独立的全局工具栏：

```
┌─────────────────────────────────────────────────────────────┐
│ [Select▼] [Move▼] [Rotate▼] [Scale▼] │ [Local▼] [Pivot▼]   │
│ [□ Grid] [◇ Snap▼] [⚙ Settings▼]     │  [▶ Play] [⏸] [⏹]  │
└─────────────────────────────────────────────────────────────┘
```

- 左侧：变换工具 + 空间/轴心/捕捉设置
- 右侧：播放控制
- 所有按钮使用 UE 风格的图标按钮（无边框，hover 高亮）

---

## 阶段四：Viewport 视口重构

### 4.1 覆盖层重组

当前 5 个独立的 ImGui 浮动窗口定位在 3D 图像上方，重构为更整洁的布局：

```
┌──────────────────────────────────────────────────────┐
│ [Select] [Move] [Rotate] [Scale]  │  [Local] [Pivot] │  ← 全局工具栏（独立）
├──────────────────────────────────────────────────────┤
│                                                      │
│                    3D Scene                          │
│                                                      │
│  [View▼] [Show▼] [Lighting▼] [Lit▼]                  │  ← 左下角快捷菜单
│                                              [ViewCube]  ← 右上角
│  FPS: 60  Entities: 42                               │  ← 底部状态
└──────────────────────────────────────────────────────┘
```

### 4.2 覆盖层变更对照

| 覆盖层 | 当前 | UE 风格 |
|--------|------|---------|
| 工具栏 | 视口内条带 | 独立全局工具栏 |
| View/Display/Snap | 左上角浮动按钮 | 左下角紧凑按钮组 |
| ViewCube | 右下角 72-92px | 右上角，更大更清晰 |
| FPS 信息 | 左下角独立窗口 | 底部状态栏集成 |
| 播放控制 | 居中浮动 | 全局工具栏右侧 |
| AI 状态 | 顶部居中 | 状态栏右侧胶囊 |
| 实体图标 | 投影 2D 图标 | 保持，样式调整 |
| 相机视锥 | 线框渲染 | 保持，颜色调整 |

### 4.3 右键菜单

视口右键菜单改为 UE 风格：

- 快速创建菜单（Actor 分类）
- 显示选项（Grid, Snap, Bounds, Collision）
- 渲染模式（Lit, Unlit, Wireframe, Shader Complexity）
- 视图预设（Perspective, Top, Front, Side）

---

## 阶段五：Outliner（Scene Hierarchy）重构

### 5.1 视觉风格

UE Outliner 特点：

- 更紧凑的行高
- 无边框，hover 行高亮
- 图标更小更精致
- 可见性/锁定按钮在行内右侧对齐


---

## 阶段六：Details（Inspector）重构

### 6.1 整体布局

UE Details Panel 特点：

- 组件头部有图标 + 名称 + 折叠箭头
- 属性以表格形式排列，标签右对齐
- 数值输入框更紧凑
- 组件间分隔线更明显

### 6.2 布局对比

```
当前 Inspector:
┌─────────────────────────────┐
│ ▼ Transform                 │
│   Position  [X] [Y] [Z]     │  ← 标签左对齐，三轴并排
│   Rotation  [X] [Y] [Z]     │
│   Scale     [X] [Y] [Z]     │
│                             │
│ ▼ Mesh                      │
│   Mesh      [Cube ▼]        │
│   Material  [Default ▼]     │
└─────────────────────────────┘

UE 风格 Details:
┌─────────────────────────────┐
│ Details                     │  ← 面板标题
│ [Entity Name________]       │  ← 名称编辑在顶部
├─────────────────────────────┤
│ ▼ Transform          [R][↺] │  ← 组件头部，重置/复制按钮
│   Location                  │
│       X [________]          │  ← 标签右对齐，每行一个轴
│       Y [________]          │
│       Z [________]          │
│   Rotation                  │
│       X [________]          │
│       Y [________]          │
│       Z [________]          │
│   Scale                     │
│       X [________]          │
│       Y [________]          │
│       Z [________]          │
├─────────────────────────────┤  ← 明显的分隔线
│ ▼ Mesh               [R][↺] │
│   Mesh          [Cube ▼]    │
│   Material      [Default ▼] │
├─────────────────────────────┤
│ [+ Add Component]           │  ← 底部添加按钮
└─────────────────────────────┘
```

### 6.3 Transform 组件改动

- 标签右对齐（当前左对齐）
- 每行一个轴（当前三个轴并排）
- 轴颜色标签改为轴左侧的小色块
- 添加重置按钮（每个组件头部）
- 添加复制/粘贴组件值按钮

### 6.4 属性行改动

```
当前：
Label:    [___drag_float___]

UE 风格：
     Label: X [_______]    ← 标签右对齐
            Y [_______]
            Z [_______]
```

---

## 阶段七：图标系统升级

### 7.1 图标风格

- 统一为 UE 风格的线性图标（更细线条）
- 统一尺寸规范
- 添加更多图标（组件类型、工具状态）

### 7.2 新增图标清单

| 类别 | 图标 |
|------|------|
| 变换工具 | Select, Move, Rotate, Scale |
| 空间模式 | Local, World |
| 轴心模式 | Pivot Center, Pivot Selection |
| 捕捉 | Grid Snap, Rotation Snap, Scale Snap |
| 渲染模式 | Lit, Unlit, Wireframe, Shader Complexity |
| 组件类型 | Transform, Mesh, Material, Camera, Light, Rigidbody, Collider, VFX, Audio, Script |
| 通用 | 重置, 复制, 粘贴, 删除, 添加, 搜索, 过滤 |

---

## 阶段八：交互体验改进

### 8.1 快捷键系统

| 快捷键 | 功能 |
|--------|------|
| Q | 选择模式 |
| W | 移动工具 |
| E | 旋转工具 |
| R | 缩放工具 |
| Ctrl+D | 复制实体 |
| Delete | 删除实体 |
| Ctrl+Z / Ctrl+Y | 撤销/重做 |
| F | 聚焦选中 |
| End | 聚焦所有 |
| Ctrl+C / Ctrl+V | 复制/粘贴组件 |
| Alt+G | 切换网格 |
| Ctrl+P | 播放/停止 |

### 8.2 拖拽改进

- 实体拖拽时显示半透明预览
- 拖拽到视口时显示放置位置指示
- 资源拖拽到视口时显示创建菜单（静态/动态/仅预览）

### 8.3 右键菜单改进

- 所有右键菜单统一风格
- 添加图标到菜单项
- 快捷键显示在右侧
- 灰色不可用项显示为禁用状态

---

## 实施顺序与工作量

### 优先级划分

```
P0 - 核心视觉（必须先完成）
├── 1. theme.zig 扩展 + 颜色方案
├── 2. initEditorStyle() 重写
├── 3. 全局工具栏分离
└── 4. Viewport 覆盖层重组

P1 - 面板重构
├── 5. Outliner (Hierarchy) 视觉重构
├── 6. Details (Inspector) 视觉重构
└── 7. 右键菜单统一风格

P2 - 细节完善
├── 8. 图标系统升级
├── 9. 快捷键系统
├── 10. 拖拽体验改进
└── 11. 魔法数字清理
```

## 技术约束

### 保持不变

- **底层框架**：Dear ImGui + C Bridge + Zig Bindings
- **抽象层**：`src/editor/ui/gui.zig` 接口不变
- **i18n 系统**：559 条消息 ID 结构不变
- **ECS 架构**：Entity/Component/World 不变
- **场景序列化**：`.guava_scene` 格式不变

### 可以改动

- 所有 `src/editor/ui/` 下的实现文件
- `src/editor/core/state.zig` 中的 UI 相关状态字段
- `src/editor/core/layer.zig` 中的样式初始化
- 图标资源（SVG 文件）
- `src/editor/ui/theme.zig` 完整重写

---

## 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 改动 viewport.zig（2500 行） | 可能引入渲染 bug | 分小步提交，每步验证渲染 |
| Dock 布局变更 | 用户自定义布局丢失 | 保留旧布局模板，提供迁移 |
| 颜色方案变更 | 视觉回归 | 截图对比关键面板 |
| 魔法数字提取 | 行为微变 | 初始值保持与当前一致 |

---

## 参考

- Unreal Editor UI 设计：https://docs.unrealengine.com/
- Dear ImGui 文档：https://github.com/ocornut/imgui/wiki
- 项目现有 UI 架构：`src/editor/ui/` 目录
