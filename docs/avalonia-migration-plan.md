# Guava Editor: Avalonia 迁移计划

> 从 Citron (CEF/React) 迁移到 Avalonia UI  
> 目标：消除双 GPU surface 合成问题，获得原生桌面性能和 MIT 授权自由

## 1. 为什么迁移

### 1.1 当前架构缺陷

```
┌────────────────────────────┐
│ Browser CALayer (CEF OSR)  │  ← 整块矩形 GPU surface
│ 全部 React UI 像素          │     需要"打洞"才能看到下层
├────────────────────────────┤
│ Scene CALayer (Engine)     │  ← 另一个独立 GPU surface
└────────────────────────────┘
```

- 两个独立渲染器 (CEF + Engine) 各自输出帧缓冲，在 OS CALayer 层做合成
- Viewport 区域需要 chroma-key (`#010201`) 或 `transparent` 打洞 → 两种方案都有问题
- 浮动面板悬浮在 viewport 上方时受双层合成制约
- chroma-key CPU 扫描有性能开销且颜色匹配脆弱
- `transparent` 方案导致 alpha 合成异常，UI 文字不可辨

### 1.2 Avalonia 如何解决

```
┌──────────────────────────────────────┐
│        Avalonia 单一渲染管线         │
│  ┌──────────┐  ┌──────────────────┐  │
│  │ 面板控件  │  │ Viewport (嵌入   │  │
│  │ (XAML)   │  │  Metal NSView    │  │
│  │          │  │  或 Composition  │  │
│  │          │  │  直绘 IOSurface) │  │
│  └──────────┘  └──────────────────┘  │
│  ┌── 浮动 Inspector ──────────┐      │
│  │ 普通 Avalonia 控件          │      │
│  │ 天然叠在 viewport 上方      │      │
│  └────────────────────────────┘      │
└──────────────────────────────────────┘
```

- Engine 纹理嵌入 UI 框架渲染管线内，不存在"打洞"
- 浮动面板、tooltip、gizmo overlay 天然在 viewport 上方
- 无需 chroma-key、无需 transparent hack

### 1.3 授权

- **Avalonia**: MIT — 闭源无限制，零合规负担
- **Qt**: LGPL v3 — 需动态链接 + 允许替换 dylib，或付费商业授权
- **Slint**: GPL v3 — 必须付费商业授权

---

## 2. 技术选型

| 组件 | React 版本 | Avalonia 替代方案 |
|------|-----------|------------------|
| UI 框架 | React 19 + Vite | **Avalonia 11.x** (.NET 8 AOT) |
| 面板停靠 | flexlayout-react | **[Dock](https://github.com/wieslawsoltes/Dock)** (MIT) |
| 代码编辑器 | @monaco-editor/react | **[AvaloniaEdit](https://github.com/AvaloniaUI/AvaloniaEdit)** (MIT) |
| 节点图 | @xyflow/react | **[NodeEditor](https://github.com/wieslawsoltes/NodeEditor)** (MIT) |
| 状态管理 | Zustand + immer | **ReactiveUI / CommunityToolkit.Mvvm** |
| Viewport 集成 | IOSurface + CALayer 双栈 | **NativeControlHost** (嵌 Metal NSView) |
| IPC (引擎) | WebSocket JSON-RPC | **System.Net.WebSockets** (复用现有协议) |
| IPC (原生) | citron.invoke (CEF) | **不再需要** — C# 直接 P/Invoke Zig dylib |
| 打包 | zig build + codesign | **dotnet publish** + `Avalonia.Native` + codesign |
| 国际化 | 自定义 useI18n | **Avalonia.Localization** 或 ResX |
| 快捷键 | 自定义 keybinding-service | **Avalonia KeyBinding / InputBinding** |

### 2.1 Viewport: NativeControlHost 方案

```csharp
// Engine 通过 IOSurface 共享帧，Avalonia 嵌入原生 Metal NSView 显示
public class EngineViewportControl : NativeControlHost
{
    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        // 创建 CAMetalLayer-backed NSView
        // 将 engine IOSurface 绑定为 layer.contents
        // CVDisplayLink 驱动刷新
    }
}
```

- Engine 继续用 IOSurface 输出帧（现有机制不变）
- `NativeControlHost` 嵌一个 `NSView` + `CAMetalLayer`，直接 `layer.contents = IOSurface`
- 没有 CEF 中间层 → 没有双 surface 合成 → 没有打洞问题
- Gizmo overlay / ViewCube 直接作为 Avalonia 控件叠在 NativeControlHost 上方

### 2.2 引擎 IPC: 复用 WebSocket JSON-RPC

现有引擎 WebSocket 协议 (`ws://127.0.0.1:9100`) **完全保留不变**。

```csharp
// C# 侧只需实现 JSON-RPC client
public class EngineRpcClient
{
    private ClientWebSocket _ws;
    public async Task<T> InvokeAsync<T>(string method, object? parameters = null);
    public event Action<string, JsonElement> OnNotification; // on:scene.changed 等
}
```

| 命名空间 | 方法数 | 说明 |
|-----------|--------|------|
| `editor` | 6 | ping, capabilities, selection, undo/redo, history, timeTravel |
| `scene` | 8 | hierarchy, create/delete/duplicate entity, save/load, spawnActor, query |
| `entity` | 12 | transform, components, fields, visibility, parent, asset ref |
| `viewport` | 12 | screenshot, gizmo, rect, window, surface, input, pick, boxSelect, renderSettings, fps |
| `material` | 20 | state, shading, color, scalar, flag, texture, graph nodes/connections |
| `animation` | 13 | states, transitions, conditions, parameters |
| `sequencer` | 16 | tracks, keyframes, playback control |
| `camera` | 7 | bookmarks, lookAlongAxis, orbit |
| `assets` | 2 | list, listProjectRoot |
| `script` | 5 | list, content, save, parameters |
| `rendersettings` | 6 | shadingMode, transformSpace, overlay, pathTrace, renderOutput |
| `playback` | 3 | play, pause, stop |
| `console` | 1 | clear |
| `utilities` | 3 | list, setOpen, remove |
| `plugin` | 5 | list, enable, disable, unload, rescan |
| `prefab` | 8 | list, entities, detail, transform, field, create, instantiate, save, delete |
| `particle` | 4 | list, getConfig, setConfig, applyPreset |
| `style` | 4 | getActive, list, setActive, setParam |
| `renderqueue` | 5 | list, add, remove, start, cancel, clearCompleted |
| `debug` | 2 | getRhiStats, resetRhiStats |
| `audio` | 2 | getMixerStatus, setBusVolume |
| `physicsviz` | 5 | getSettings, setDrawMode, setToggle, setFloat, setColor |
| `mesh` | 15 | getState, enter/exitEditMode, selectionMode, extrude, inset, bevel, loopCut 等 |
| `collaboration` | 3 | stage, apply, discard |

**订阅事件 (引擎 → 编辑器):**

| 事件 | 触发场景 |
|------|---------|
| `on:scene.changed` | 实体创建/删除/修改 |
| `on:selection.changed` | 选中变更 |
| `on:console.log` / `on:console.logs` | 日志输出 |
| `on:viewport.metrics` | FPS/DrawCalls/Triangles |
| `on:playback.stateChanged` | Play/Pause/Stop |
| `on:asset.changed` | 资产变更 |
| `on:editor.historyChanged` | Undo/Redo 栈变更 |
| `on:mesh.stateChanged` | Mesh 编辑模式变更 |

### 2.3 原生功能: P/Invoke 替代 Citron

CEF Citron shell 提供的原生功能，在 Avalonia 中的替代：

| citron.invoke 方法 | Avalonia 替代 |
|-------------------|--------------|
| `launcher.*` | **C# 直接实现**，用 `System.IO` + `System.Text.Json` 管理 recent projects |
| `fs.*` | **System.IO** — `Directory.CreateDirectory`, `File.Move`, `File.Delete` 等 |
| `viewport.*` | **NativeControlHost** — 直接操作 `CAMetalLayer` + IOSurface |
| `dialog.open` | **Avalonia StorageProvider** — 跨平台文件/文件夹对话框 |
| `window.create` / `popout.*` | **Avalonia Window** — `new Window { Content = panel }` |
| `build.*` | **P/Invoke** 调 Zig 编译的 `libguava_build.dylib` 或 `Process.Start("zig", "build ...")` |

---

## 3. 项目结构

```
Guava/
  packages/
    editor-avalonia/                     # 新增
      Guava.Editor.sln
      src/
        Guava.Editor/                    # 主项目
          Guava.Editor.csproj
          Program.cs                     # 入口
          App.axaml + App.axaml.cs       # Avalonia Application
          ViewModels/
            MainWindowViewModel.cs
            LauncherViewModel.cs
            ViewportViewModel.cs
            SceneHierarchyViewModel.cs
            InspectorViewModel.cs
            MaterialEditorViewModel.cs
            ConsoleViewModel.cs
            ContentBrowserViewModel.cs
            TimelineViewModel.cs
            SequencerViewModel.cs
            AnimationEditorViewModel.cs
            MaterialGraphViewModel.cs
            AiChatViewModel.cs
            RenderSettingsViewModel.cs
            PlaceActorsViewModel.cs
            RenderQueueViewModel.cs
            PhysicsVizViewModel.cs
            PostFxEditorViewModel.cs
            PluginManagerViewModel.cs
            CameraBookmarksViewModel.cs
            RhiStatsViewModel.cs
            AudioMixerViewModel.cs
            ParticleEditorViewModel.cs
            PrefabEditorViewModel.cs
            SkyPanelViewModel.cs
            StyleInspectorViewModel.cs
            AssetManagerViewModel.cs
            SettingsViewModel.cs
            ScriptEditorViewModel.cs
            BuildDialogViewModel.cs
          Views/
            MainWindow.axaml            # 主窗口 (Dock 布局)
            LauncherView.axaml          # 项目启动器
            Panels/
              ViewportPanel.axaml       # NativeControlHost + ViewCube overlay
              SceneHierarchyPanel.axaml # 树形场景层级
              InspectorPanel.axaml      # 属性检查器 + 组件字段编辑器
              MaterialEditorPanel.axaml
              ConsolePanel.axaml
              ContentBrowserPanel.axaml
              TimelinePanel.axaml
              SequencerPanel.axaml
              AnimationEditorPanel.axaml
              MaterialGraphPanel.axaml  # NodeEditor 集成
              AiChatPanel.axaml
              RenderSettingsPanel.axaml
              PlaceActorsPanel.axaml
              RenderQueuePanel.axaml
              PhysicsVizPanel.axaml
              PostFxEditorPanel.axaml
              PluginManagerPanel.axaml
              CameraBookmarksPanel.axaml
              RhiStatsPanel.axaml
              AudioMixerPanel.axaml
              ParticleEditorPanel.axaml
              PrefabEditorPanel.axaml
              SkyPanel.axaml
              StyleInspectorPanel.axaml
              AssetManagerPanel.axaml
              ScriptEditorPanel.axaml
            Components/
              Toolbar.axaml
              ViewportStatus.axaml
              ViewCube.axaml
              BuildDialog.axaml
              SettingsPanel.axaml
              KeybindingsPanel.axaml
              ContextMenu.axaml
              ToastContainer.axaml
              MeshEditToolbar.axaml
          Services/
            EngineRpcClient.cs          # WebSocket JSON-RPC 客户端
            EngineRpcSubscriptions.cs   # 事件订阅分发
            ProjectService.cs           # 项目管理 (recent, create, open)
            FileSystemService.cs        # 文件操作
            BuildService.cs             # 构建/打包
            AiService.cs                # LLM 多 Provider + 工具调用
            KeybindingService.cs        # 快捷键管理
            I18nService.cs              # 国际化
            LayoutService.cs            # Dock 布局持久化
          Models/
            SceneEntity.cs
            ComponentField.cs
            MaterialState.cs
            RenderSettings.cs
            ConsoleLogEntry.cs
            AssetInfo.cs
            AnimationState.cs
            SequencerState.cs
            AiMessage.cs
            ProjectInfo.cs
          Native/
            IOSurfaceBridge.cs          # P/Invoke: IOSurface APIs
            MetalViewHost.cs            # NSView + CAMetalLayer 宿主
            DisplayLinkBridge.cs        # CVDisplayLink P/Invoke
          Converters/
            EntityIconConverter.cs
            LogLevelColorConverter.cs
            FpsColorConverter.cs
            AssetTypeIconConverter.cs
          Themes/
            CatppuccinMocha.axaml       # 暗色主题 (匹配现有 #1e1e2e 色系)
        Guava.Editor.Desktop/           # 桌面平台入口
          Guava.Editor.Desktop.csproj
          Program.cs
    editor/                             # 保留 React 版本作参考
    engine/                             # 不动
  citron/                               # 废弃 (迁移完成后删除)
```

---

## 4. 里程碑

### Phase 1: 基础骨架 (Q1–Q3)

| CP | 内容 | 交付物 | 验收标准 |
|----|------|--------|----------|
| **Q1** | 项目初始化 + 空窗口 | .sln + .csproj + App.axaml + MainWindow | `dotnet run` 弹出空窗口，macOS 原生标题栏 |
| **Q2** | Dock 布局 + 面板骨架 | 集成 Dock 库，26 个空面板注册 | 面板可拖动/吸附/浮动/关闭/恢复，布局持久化 |
| **Q3** | Launcher | LauncherView + ProjectService | 最近项目列表、新建/打开项目、模板选择 |

### Phase 2: 引擎连接 (Q4–Q6)

| CP | 内容 | 交付物 | 验收标准 |
|----|------|--------|----------|
| **Q4** | Engine RPC Client | EngineRpcClient + 订阅分发 | 连接 `ws://127.0.0.1:9100`，ping 成功，收到 `on:scene.changed` |
| **Q5** | Viewport (IOSurface) | NativeControlHost + MetalViewHost + IOSurfaceBridge | 引擎画面显示在面板内，跑满 120fps |
| **Q6** | Viewport 输入 + Gizmo | 鼠标/键盘转发 + ViewCube + 状态栏 | 点选/框选、Translate/Rotate/Scale、FPS/DrawCalls 显示 |

### Phase 3: 核心面板 (Q7–Q12)

| CP | 内容 | 交付物 | 验收标准 |
|----|------|--------|----------|
| **Q7** | Scene Hierarchy | 树形控件 + 搜索 + 右键菜单 + 拖放重父 | 实体树同步，创建/删除/复制/重命名 |
| **Q8** | Inspector | 属性面板 + 组件字段编辑器 (float/vec3/color/enum/asset_ref) | 选中实体 → 显示组件 → 编辑字段 → 引擎同步 |
| **Q9** | Console | 日志列表 + 级别过滤 + 搜索 + 自动滚动 | 引擎日志实时显示，颜色编码 |
| **Q10** | Content Browser | 树形目录 + 资产类型图标 + 右键操作 + 拖放导入 | 浏览/创建/删除/重命名文件和目录 |
| **Q11** | Toolbar + Playback | 顶部工具栏 + 保存/Undo/Redo/Play/Pause/Stop | Play 模式切换，Gizmo 模式切换 |
| **Q12** | Material Editor | PBR 属性面板 + 纹理槽位 + Shading 切换 | 编辑材质 → 引擎实时预览 |

### Phase 4: 高级面板 (Q13–Q20)

| CP | 内容 | 交付物 | 验收标准 |
|----|------|--------|----------|
| **Q13** | Script Editor | AvaloniaEdit + Zig 语法高亮 + 多标签 | 打开/编辑/保存脚本，Zig 语法着色 |
| **Q14** | Material Graph | NodeEditor 集成 + 节点类型 + 连线 | 添加/连接/删除节点，材质通道输出 |
| **Q15** | Render Settings | 完整后处理参数面板 | Bloom/SSAO/TAA/DOF 等参数调整 |
| **Q16** | Sequencer | 多轨道时间线 + 关键帧编辑 + 播放控制 | 创建序列，添加轨道/关键帧，播放预览 |
| **Q17** | Animation Editor | 状态机编辑 + 过渡/条件 | 动画状态添加/连接/参数配置 |
| **Q18** | AI Chat | 多 Provider 聊天 + 工具调用 + 流式响应 | 对话 → AI 调用引擎工具 → 场景变更 |
| **Q19** | Build Dialog | 优化级别选择 + 进度日志 + 运行 | Debug/Release 构建并运行 |
| **Q20** | Place Actors | 分类目录 + 搜索 + 一键生成 | 选择 Actor 类型 → 场景中生成 |

### Phase 5: 辅助面板 + 收尾 (Q21–Q28)

| CP | 内容 | 交付物 | 验收标准 |
|----|------|--------|----------|
| **Q21** | Timeline (Undo History) | 历史栈可视化 + 时间旅行 | 点击历史条目跳转 |
| **Q22** | Camera Bookmarks | 摄像机位置保存/恢复 | 书签列表增删改 |
| **Q23** | Plugin Manager | 插件列表 + 启用/禁用 | 插件管理 |
| **Q24** | 其他面板批量完成 | RHI Stats, Audio Mixer, Particle Editor, Prefab Editor, Sky Panel, Style Inspector, Physics Viz, Asset Manager, Render Queue, Post-FX Editor | 全部 26 面板功能对齐 |
| **Q25** | Settings + Keybindings | 设置面板 + 快捷键配置 | 语言/外观/键绑定 |
| **Q26** | 弹出窗口 | 面板弹出到独立窗口 | 右键 tab → Pop Out |
| **Q27** | 国际化 | 英文 + 中文 | 语言切换 |
| **Q28** | 打包发布 | dotnet publish AOT + codesign + DMG | 双击 .app 可运行 |

---

## 5. 关键技术细节

### 5.1 IOSurface → Metal → NativeControlHost

```
Engine (Zig/Metal)
  │
  ├─ 渲染到 IOSurface (IOSurfaceCreate / IOSurfaceGetID)
  │
  └─ 通过 WebSocket RPC 返回 surfaceId
        │
        ▼
Avalonia (C#)
  │
  ├─ IOSurfaceBridge.cs
  │    [DllImport("IOSurface")] IOSurfaceLookup(surfaceId)
  │
  ├─ MetalViewHost.cs
  │    NSView + CAMetalLayer
  │    layer.contents = IOSurfaceRef  (零拷贝)
  │
  ├─ DisplayLinkBridge.cs
  │    CVDisplayLink → 回调刷新 layer.contents
  │
  └─ NativeControlHost
       嵌入 Avalonia 控件树
       ViewCube/Gizmo overlay 叠在上方 (普通 Avalonia 控件)
```

**关键点：**
- `IOSurfaceLookup` + `CAMetalLayer.contents` = 零拷贝 GPU 纹理共享
- 不需要 CEF/浏览器层 → 没有 chroma-key/transparent 问题
- 浮动面板自然叠在 Viewport 上方

### 5.2 Engine RPC 协议复用

```csharp
public class EngineRpcClient : IDisposable
{
    private readonly ClientWebSocket _ws = new();
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private int _nextId;

    public async Task ConnectAsync(string url = "ws://127.0.0.1:9100")
    {
        await _ws.ConnectAsync(new Uri(url), CancellationToken.None);
        _ = Task.Run(ReceiveLoopAsync);
    }

    public async Task<T> InvokeAsync<T>(string method, object? @params = null)
    {
        var id = Interlocked.Increment(ref _nextId);
        var msg = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params });
        // ... send and await response
    }

    // 订阅: on:scene.changed, on:selection.changed, on:viewport.metrics 等
    public event Action<string, JsonElement>? OnNotification;
}
```

**零协议改动**。所有 160+ RPC 方法和 8 个订阅事件直接复用。

### 5.3 Dock 布局

```csharp
// 使用 Dock 库 (MIT) — 和 flexlayout-react 功能等价
var factory = new GuavaDockFactory();
var layout = factory.CreateDefaultLayout(); // 26 个面板的默认排列

// 布局持久化 (等价于 flexlayout localStorage)
var json = factory.Serialize(layout);
File.WriteAllText(layoutPath, json);
```

### 5.4 AvaloniaEdit 代码编辑器

```csharp
// 等价于 @monaco-editor/react
var editor = new TextEditor
{
    SyntaxHighlighting = ZigSyntaxHighlighting.Instance, // 自定义 Zig 语法
    ShowLineNumbers = true,
    Options = { EnableHyperlinks = false, ConvertTabsToSpaces = true }
};
```

需自定义 Zig 语法高亮 (基于现有 Monarch 定义迁移到 AvaloniaEdit 的 IHighlightingDefinition)。

### 5.5 NodeEditor 材质图

```csharp
// 等价于 @xyflow/react 材质图编辑器
// 节点类型: input_parameter, constant, texture_sample, math_add/multiply,
//           split_channels, normal_map, output
// 通道: base_color, metallic, roughness, normal, occlusion, emissive, alpha_cutoff
```

### 5.6 主题

匹配现有 Catppuccin Mocha 色系：

```xml
<!-- CatppuccinMocha.axaml -->
<Style>
  <Style.Resources>
    <Color x:Key="Base">#1e1e2e</Color>
    <Color x:Key="Mantle">#181825</Color>
    <Color x:Key="Crust">#11111b</Color>
    <Color x:Key="Surface0">#313244</Color>
    <Color x:Key="Surface1">#45475a</Color>
    <Color x:Key="Blue">#89b4fa</Color>
    <Color x:Key="Text">#cdd6f4</Color>
  </Style.Resources>
</Style>
```

---

## 6. 迁移策略

### 6.1 增量迁移，并行运行

- Avalonia 编辑器 (`editor-avalonia/`) 和 React 编辑器 (`editor/`) 并行存在
- 两者连接同一个引擎 (`ws://127.0.0.1:9100`)，可以交替测试
- React 版本作为功能参考，直到 Avalonia 版本全部面板对齐后删除
- Citron shell 在 Avalonia 完成后废弃

### 6.2 不迁移的部分

- **引擎代码** (`packages/engine/`): 完全不动
- **WebSocket 协议**: 完全不动
- **IOSurface 共享机制**: Engine 侧不动，仅 host 侧从 CEF CALayer 改为 Avalonia NativeControlHost
- **AI 工具定义**: 引擎侧的 44 个 AI tool 不动，Avalonia 侧重新实现 AI chat client

### 6.3 需要重写的部分

| 层 | React 版本 | Avalonia 重写 |
|----|-----------|--------------|
| 壳 | Citron (CEF/Zig) | Avalonia.Desktop (C#) |
| UI 控件 | React TSX + CSS | AXAML + C# |
| 状态管理 | Zustand stores (10个) | ViewModels (MVVM) |
| RPC client | TypeScript WebSocket | C# ClientWebSocket |
| 文件系统 | citron.invoke('fs.*') | System.IO |
| 对话框 | citron.invoke('dialog.*') | Avalonia StorageProvider |
| 布局 | flexlayout-react | Dock |
| 编辑器 | Monaco | AvaloniaEdit |
| 节点图 | @xyflow/react | NodeEditor |

---

## 7. 风险与缓解

| 风险 | 严重度 | 缓解措施 |
|------|--------|---------|
| NativeControlHost + IOSurface 集成可能有 Avalonia 版本兼容问题 | 高 | Q5 前做 PoC spike，验证 IOSurface → CAMetalLayer → NativeControlHost 管线 |
| AvaloniaEdit 对 Zig 语法高亮的支持质量 | 中 | 自定义 IHighlightingDefinition，从 Monarch 定义转换 |
| NodeEditor 库功能不足以实现材质图 | 中 | Q14 前做 PoC；不行则用 Avalonia Canvas 自绘 |
| Dock 库的面板弹出窗口支持 | 低 | Dock 原生支持浮动窗口 |
| .NET AOT 在 macOS 的打包体积 | 低 | self-contained publish + strip，预期 20-40MB |
| macOS 公证 (notarization) | 低 | `dotnet publish` + `codesign` + `xcrun notarytool` |

---

## 8. 依赖清单

### NuGet 包

| 包 | 版本 | 用途 |
|----|------|------|
| Avalonia | 11.x | UI 框架 |
| Avalonia.Desktop | 11.x | macOS/Windows/Linux 宿主 |
| Avalonia.Themes.Fluent | 11.x | 基础主题 (基础上自定义) |
| CommunityToolkit.Mvvm | 8.x | MVVM 基础设施 |
| Dock.Avalonia | 11.x | 可停靠面板 |
| AvaloniaEdit | 11.x | 代码编辑器 |
| NodeEditor.Avalonia | latest | 节点图编辑器 |
| System.Text.Json | (内置) | JSON 序列化 |

### 原生依赖 (P/Invoke)

| 框架/库 | 用途 |
|---------|------|
| IOSurface.framework | IOSurfaceLookup, IOSurfaceGetID |
| Metal.framework | MTLDevice, CAMetalLayer |
| CoreVideo.framework | CVDisplayLink |
| AppKit.framework | NSView 创建 |

---

## 9. 验收标准

迁移完成的定义：

1. ✅ 全部 26 个面板功能与 React 版本对齐
2. ✅ Viewport 引擎画面零拷贝显示，浮动面板正确叠加
3. ✅ 无 chroma-key / transparent / 双 surface 合成问题
4. ✅ 引擎 IPC 全部 160+ RPC 方法和 8 个订阅事件正常工作
5. ✅ 脚本编辑器支持 Zig 语法高亮
6. ✅ 材质节点图编辑器功能对齐
7. ✅ macOS .app 打包可运行、签名通过
8. ✅ 启动 → Launcher → 打开项目 → 编辑 → 构建 → 运行 完整流程跑通
9. ✅ AI Chat 多 Provider 对话 + 工具调用 循环正常
10. ✅ 中英文语言切换

---

## 10. 时间线概览

```
Phase 1: 基础骨架         Q1 ─ Q3     项目初始化 + Dock + Launcher
Phase 2: 引擎连接         Q4 ─ Q6     RPC + Viewport + 输入
Phase 3: 核心面板         Q7 ─ Q12    Hierarchy + Inspector + Console + ContentBrowser + Toolbar + Material
Phase 4: 高级面板         Q13 ─ Q20   Script + MaterialGraph + Sequencer + AI Chat + ...
Phase 5: 收尾打包         Q21 ─ Q28   辅助面板 + Settings + i18n + 打包
```
