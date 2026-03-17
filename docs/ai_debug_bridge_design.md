# Guava Engine AI Debug Bridge 设计文档

本文定义 Guava Engine 的 AI Debug Bridge 设计，目标是让外部 AI 真正“看懂”当前引擎状态，并能够以受控方式协助调试渲染、UI、场景数据和运行时问题。

本文不是泛化的“远程调试器”设计，而是面向当前 Guava Engine 代码结构的专用方案。设计优先考虑以下现实约束：

- 当前引擎是 Zig + SDL3 + SDL GPU + ImGui 原生桥。
- 当前调试信息已经零散存在于 `RenderGraph` 报告、`FrameReport`、控制台日志、世界序列化与少量 GPU 读回中。
- 当前 AI 最容易消费的是结构化文本与图像，而不是进程内对象、原始调用栈或交互式 GUI 状态。
- 当前阶段最需要的是“让 AI 获得足够上下文”，而不是先做一个复杂的远程执行系统。

因此，本设计采用以下路线：

1. 先定义**可离线分享的快照包**。
2. 再定义**本地 Agent 可消费的命令桥**。
3. 最后才引入**崩溃捕获与更深层自动化调试**。

## 1. 设计目标

AI Debug Bridge 的目标是：

- 让 AI 能够在不运行引擎源码调试器的情况下，理解场景、渲染、UI 与输入上下文。
- 让 AI 能够判断问题是出在数据、资源、布局、渲染状态还是交互状态。
- 让 AI 能够基于统一格式输出可执行的修复建议。
- 在需要时，允许本地 Agent 通过白名单命令修改有限的运行时状态。

本设计明确不追求：

- 让 AI 获得任意代码执行能力。
- 让 AI 直接替代本地调试器、图形 API 捕获器或平台级 crash reporter。
- 在第一版中覆盖所有 GPU 中间资源的完整图像导出。

## 2. 当前仓库可复用基础

本设计建立在当前仓库已经存在的能力之上：

- `src/engine/render/render_graph.zig`
  - 已能导出 `render_graph.dot` 与 `render_graph.json`
  - 已能输出 `latest_frame_report.json`
- `src/engine/render/renderer.zig`
  - 每帧写入渲染报告
  - 已具备 ID Pass、选择读回与部分 GPU 读回通路
- `src/editor/ui/windows/console.zig`
  - 已有线程安全日志缓存与 `snapshot()` 接口
- `src/editor/actions/history.zig`
  - 已能通过 `serializeWorldAlloc()` 导出世界状态
- `src/engine/ui/imgui_bridge.cpp`
  - 已包含 `imgui_internal.h`
  - 已有访问窗口焦点、悬停、尺寸等能力的桥接基础
- `src/engine/rhi/device.zig`
  - 已支持单像素 `downloadTexturePixel()` 与 `readTexturePixel()`

这意味着 AI Debug Bridge 不是从零开始，而是把已有信息统一组织成 AI 可消费的规范。

## 3. 核心设计原则

### 3.1 结构优先，截图其次

AI 调试引擎问题时，最重要的不是一张图片，而是图片背后的结构化上下文。截图只能告诉 AI “看起来不对”，不能告诉 AI “为什么不对”。

因此：

- 所有快照必须以 `manifest.json` 为入口。
- 所有主要状态必须导出为 JSON 或 JSONL。
- 图片只作为辅助材料，不可作为唯一信息源。

### 3.2 稳定字段名与版本号

AI 要反复消费同一种调试输出，格式必须稳定。每个文件都必须有：

- `schema`
- `version`
- `captured_at_utc`

字段命名要求：

- 使用明确英文 key，避免 UI 文案或自然语言混入结构字段。
- enum 必须稳定，不能输出本地化文本。
- 所有 ID 必须保留原始数值与可读名称。

### 3.3 去歧义的单位与坐标系

AI 很容易被“这是像素还是世界单位”“这是逻辑尺寸还是 drawable 尺寸”这类歧义误导。

因此所有相关输出必须显式标记：

- 世界坐标系：`Y-up`、右手或左手、单位默认为米。
- 旋转单位：弧度。
- UI 坐标：逻辑像素。
- GPU 纹理尺寸：drawable 像素。

### 3.4 既要原始数据，也要派生诊断

仅导出原始状态还不够。AI 应当看到一份机器友好的“问题提示列表”，减少它自己做低级一致性检查的成本。

因此快照中必须包含：

- `integrity_report.json`
- `ui_findings.json`
- `render_findings.json`

这些文件由引擎本身生成，列出可自动发现的异常，例如：

- 主摄像机不存在。
- 选中的实体不存在。
- 材质引用缺失。
- 视口尺寸为零。
- 窗口超出可见区域。
- 资源句柄无效。
- draw item 数量为零但场景有网格实体。

### 3.5 白名单命令而非任意执行

AI 在第二阶段可以协助修改状态，但不能拥有任意执行能力。

因此：

- 不实现 `/eval`
- 不实现任意脚本执行
- 只提供受控命令，如 `set_transform`、`select_entity`、`capture_snapshot`

## 4. 系统总览

AI Debug Bridge 分为四层：

1. **Snapshot Layer**
   - 一次性导出完整快照目录
2. **Inspector Layer**
   - 导出世界、渲染、UI、日志、输入的结构化状态
3. **Command Layer**
   - 接收受控命令并修改有限状态
4. **Crash Layer**
   - 在崩溃时导出最小可分析信息

对当前项目的推荐实施顺序是：

1. Snapshot Layer
2. Inspector Layer
3. UI Inspector 扩展
4. Command Layer
5. Crash Layer

## 5. 快照包格式

### 5.1 输出目录

第一版不强制 zip。输出目录建议为：

```text
dist/ai_debug/2026-03-17T13-48-22Z/
```

目录内容建议如下：

```text
manifest.json
world.json
world_summary.json
selection.json
viewport_state.json
window_state.json
input_state.json
render_graph.json
frame_report.json
render_state.json
render_findings.json
ui_windows.json
ui_items.json
ui_findings.json
console.jsonl
integrity_report.json
viewport.png
scene_id_buffer.png
```

说明：

- `scene_id_buffer.png` 不是第一版必须项，可以先留空。
- 如果截图还未实现整图读回，可以先跳过图片，但 `manifest.json` 必须标记哪些文件缺失。

### 5.2 manifest.json

这是 AI 的入口文件，AI 必须优先读取它。

示例结构：

```json
{
  "schema": "guava.ai_debug.manifest",
  "version": 1,
  "captured_at_utc": "2026-03-17T13:48:22Z",
  "trigger": {
    "kind": "manual_hotkey",
    "reason": "user_requested_snapshot"
  },
  "build": {
    "git_commit": "8bb856c",
    "git_branch": "main",
    "config": "debug"
  },
  "runtime": {
    "platform": "macos",
    "graphics_api": "vulkan",
    "window_logical_size": [1600, 960],
    "window_drawable_size": [3200, 1920],
    "frame_index": 4812
  },
  "entry_files": {
    "world": "world.json",
    "render_graph": "render_graph.json",
    "frame_report": "frame_report.json",
    "render_state": "render_state.json",
    "ui_windows": "ui_windows.json",
    "console": "console.jsonl",
    "integrity_report": "integrity_report.json",
    "viewport_image": "viewport.png"
  },
  "capture_capabilities": {
    "full_texture_readback": false,
    "ui_item_rects": true,
    "command_bridge_enabled": false
  }
}
```

要求：

- `entry_files` 必须是相对路径。
- 缺失文件必须在 `capture_capabilities` 或附加字段中说明原因。

## 6. 世界状态导出规范

### 6.1 world.json

`world.json` 应包含 AI 理解场景所需的完整 ECS 状态。不能只复用编辑器存档格式原样输出；需要在不破坏现有序列化的前提下，增加一份**AI 友好的扁平视图**。

建议结构：

```json
{
  "schema": "guava.ai_debug.world",
  "version": 1,
  "summary": {
    "entity_count": 42,
    "mesh_entity_count": 12,
    "light_entity_count": 3,
    "camera_entity_count": 2
  },
  "entities": [
    {
      "id": 7,
      "name": "MainCamera",
      "parent": null,
      "visible": true,
      "editor_only": false,
      "is_folder": false,
      "transform_local": {
        "translation": [0.0, 1.5, 5.0],
        "rotation_euler_radians": [0.0, 0.0, 0.0],
        "scale": [1.0, 1.0, 1.0]
      },
      "transform_world": {
        "translation": [0.0, 1.5, 5.0],
        "rotation_euler_radians": [0.0, 0.0, 0.0],
        "scale": [1.0, 1.0, 1.0]
      },
      "components": {
        "camera": {
          "is_primary": true,
          "projection_kind": "perspective",
          "fov_y_radians": 1.0471976,
          "near_clip": 0.1,
          "far_clip": 1000.0
        }
      },
      "resource_refs": {
        "mesh_asset_id": null,
        "material_asset_id": null
      },
      "bounds": {
        "local_aabb": null,
        "world_aabb": null
      }
    }
  ]
}
```

### 6.2 AI 友好要求

对于每个实体，必须同时提供：

- 基础标志位
- 局部变换
- 世界变换
- 组件扁平信息
- 资源引用
- 包围体信息

不能要求 AI 去二次推导：

- “世界变换是多少”
- “材质引用的 asset id 是什么”
- “这个实体为什么不可选”

### 6.3 resource_refs

对 AI 来说，句柄值本身信息不足。必须同时导出：

- handle 数值
- asset id
- 资源名
- 来源路径

例如：

```json
"resource_refs": {
  "mesh": {
    "handle": 5,
    "asset_id": "guava.gltf.mesh.v1:...",
    "name": "Hero_mesh_0",
    "source_path": "assets/models/hero/hero.gltf#mesh/Hero_mesh_0"
  }
}
```

## 7. 选择、视口、窗口与输入导出规范

### 7.1 selection.json

必须包含：

- 当前 primary selection
- 当前 selection 列表
- 当前 editor camera / scene camera
- 选中实体是否存在

### 7.2 viewport_state.json

必须包含：

- render mode
- 是否显示 grid / bones / collision
- viewport hovered / focused
- viewport origin 与 extent
- viewport 是否有图像
- 当前 view preset

数据来源主要是 `EditorState` 与 `Renderer.sceneViewportSize()`。

### 7.3 window_state.json

必须包含：

- 逻辑尺寸
- drawable 尺寸
- 是否高 DPI
- 原生标题栏模式
- 平台

数据来源主要是 `Window`。

### 7.4 input_state.json

必须包含：

- 鼠标逻辑坐标
- 鼠标按钮状态
- 键盘修饰键
- 是否被 ImGui 捕获鼠标
- 是否被 ImGui 捕获键盘

否则 AI 很难判断“按钮点不到”究竟是布局问题、输入问题还是 capture 问题。

## 8. 渲染状态导出规范

### 8.1 render_graph.json 与 frame_report.json

继续复用现有输出，但必须保证：

- 快照包中始终复制最新版本，而不是只依赖 `dist/reports/` 全局文件。
- `manifest.json` 明确指向本次快照使用的副本。

### 8.2 render_state.json

除了 graph 和 frame report，还必须补一份“当前帧实际渲染状态视图”，因为仅靠 RenderGraph 还无法回答以下问题：

- 当前场景视口是否启用离屏纹理
- ID Pass 目标尺寸是否正确
- 当前 SceneViewport 是否存在颜色/深度纹理
- 当前 draw item 数量是多少
- 当前主相机与主灯光被解析成了什么

建议结构：

```json
{
  "schema": "guava.ai_debug.render_state",
  "version": 1,
  "scene_viewport": {
    "active": true,
    "width": 1440,
    "height": 900,
    "color_target": {
      "format": "bgra8_unorm"
    },
    "depth_target": {
      "format": "d32_float"
    }
  },
  "id_pass": {
    "ready": true,
    "width": 1440,
    "height": 900,
    "format": "bgra8_unorm"
  },
  "prepared_scene": {
    "draw_item_count": 18,
    "camera_world_position": [0.0, 1.5, 5.0],
    "main_light": {
      "kind": "directional",
      "direction": [0.3, -0.9, -0.2]
    },
    "point_light": {
      "enabled": true,
      "position": [2.0, 3.0, 1.0],
      "range": 10.0
    }
  }
}
```

### 8.3 render_findings.json

用于列出引擎自己能检测的渲染异常，例如：

- `scene_has_mesh_entities_but_draw_item_count_is_zero`
- `id_pass_texture_size_mismatch`
- `viewport_is_active_but_viewport_texture_missing`
- `base_pass_not_ready`
- `selected_entities_present_but_outline_pass_skipped`

这类派生结论会显著提升 AI 的判断准确率。

## 9. 日志导出规范

### 9.1 console.jsonl

日志不要导出成一个大段字符串，应该逐行 JSON，便于 AI 检索和过滤。

建议每行结构：

```json
{"index":0,"level":"warn","scope":"renderer","message":"failed to write frame report: PermissionDenied"}
```

要求：

- 记录日志顺序
- 保留 level
- 保留 scope
- 保留原消息

第一版可直接基于 `console.snapshot()` 输出最近 `N` 条。

## 10. UI 调试导出规范

这是 Guava Engine 中最重要、也最容易被低估的一部分。

### 10.1 为什么截图不够

ImGui 是即时模式 UI，没有 DOM 树。对 AI 来说，仅凭截图很难判断：

- 窗口被 dock 到哪里
- 哪个窗口获得焦点
- 哪个控件实际接收输入
- 某个按钮不可点击是因为遮挡、尺寸为零还是 capture 状态

### 10.2 ui_windows.json

必须导出所有活跃窗口的布局信息。建议通过 `imgui_internal.h` 访问 `ImGuiContext` 的窗口数组。

每个窗口至少包含：

- `name`
- `pos`
- `size`
- `viewport_id`
- `dock_id`
- `collapsed`
- `hidden`
- `appearing`
- `focused`
- `hovered`
- `active`

建议结构：

```json
{
  "schema": "guava.ai_debug.ui_windows",
  "version": 1,
  "windows": [
    {
      "name": "Inspector##panel.inspector",
      "pos": [1198.0, 42.0],
      "size": [402.0, 878.0],
      "dock_id": 124821,
      "collapsed": false,
      "focused": true,
      "hovered": false
    }
  ]
}
```

### 10.3 ui_items.json

第二层是关键控件矩形。不是所有控件都要导出，而是导出**具备调试价值的关键控件**：

- 视口图像区域
- 顶部工具栏按钮
- 播放控制按钮
- Inspector 主要分组
- 资产浏览器网格项
- 当前 hovered item
- 当前 active item

建议通过桥接 API 提供一组调试标记函数，例如：

- `beginDebugUiCapture()`
- `recordDebugItemRect(id, kind, entity_id, asset_id)`
- `endDebugUiCapture()`

这样 Zig UI 层可以在关键绘制点显式打标签，而不是要求 C++ 侧猜测每个控件语义。

每条记录至少包含：

- `id`
- `kind`
- `window_name`
- `rect_min`
- `rect_max`
- `hovered`
- `active`
- `entity_id` 或 `asset_id`

### 10.4 ui_findings.json

由引擎自动检测：

- 窗口完全超出主视口
- 窗口尺寸为零或极小
- 视口区域尺寸异常
- 播放工具栏拖出屏幕
- Inspector 与 Hierarchy 重叠异常

## 11. 图像导出规范

### 11.1 viewport.png

优先导出编辑器场景视口的颜色纹理，而不是 swapchain。

原因：

- 场景视口是用户真正关心的编辑区域。
- 当 UI 叠加较多时，swapchain 容易混入不稳定元素。
- 当前 `Renderer` 已经有 `SceneViewportState`，更适合定向导出。

### 11.2 scene_id_buffer.png

这是可选项。若实现：

- 导出 ID Pass 颜色结果
- 用于 AI 判断“选取为什么不准”“实体 ID 编码是否错位”

### 11.3 整图读回要求

当前 RHI 只有单像素读回。Bridge 必须新增“整张纹理下载”能力，不能用逐像素循环代替。

建议新增：

- `downloadTextureRegion()`
- `readTextureBytes()`

然后由调试桥统一写出 PNG。

## 12. integrity_report.json

这是桥接层最关键的 AI 友好文件之一。

它应该列出跨模块一致性问题，而不是仅记录原始状态。

建议分组：

- `world`
- `resources`
- `render`
- `ui`
- `input`

示例：

```json
{
  "schema": "guava.ai_debug.integrity_report",
  "version": 1,
  "issues": [
    {
      "severity": "error",
      "code": "selected_entity_missing",
      "message": "Primary selection points to entity 42, but entity is absent from world."
    },
    {
      "severity": "warn",
      "code": "viewport_zero_extent",
      "message": "Viewport window is focused but extent is [0,0]."
    }
  ]
}
```

推荐自动检查项：

- 主摄像机不存在
- 选中实体不存在
- 实体引用的 mesh/material/texture 句柄无效
- 场景有 mesh 实体但 draw item 数量为零
- 视口处于 active 状态但纹理不存在
- viewport origin/extent 非法
- 资产浏览器选中项越界
- 预览纹理 key 与纹理对象不一致

## 13. 命令桥设计

第二阶段才启用命令桥。

### 13.1 传输方式

优先级建议如下：

1. 本地命令文件轮询
2. Unix Domain Socket / Named Pipe
3. 本地 HTTP

原因：

- 文件轮询最容易实现和调试。
- 本地 socket 比 HTTP 更适合作为受控调试通道。
- HTTP 只在你明确需要外部进程或脚本轮询时再上。

### 13.2 命令原则

- 只能执行白名单命令
- 每条命令必须有 `id`
- 每条命令必须返回结果文件或响应对象
- 所有副作用必须记录到 `command_log.jsonl`

### 13.3 推荐命令集

第一版只允许：

- `capture_snapshot`
- `select_entity`
- `replace_selection`
- `set_transform`
- `set_viewport_flag`
- `focus_selection`
- `reload_asset_registry`
- `clear_console`

示例：

```json
{
  "id": "cmd-1042",
  "command": "set_transform",
  "entity_id": 12,
  "translation": [0.0, 10.0, 0.0]
}
```

禁止：

- 任意脚本执行
- 任意文件写入
- 任意内存访问
- 任意图形 API 命令插入

## 14. Crash Layer 设计

崩溃捕获不是第一阶段目标，但设计上必须预留。

### 14.1 崩溃时最低输出

发生崩溃时，尽量写出：

- `crash_manifest.json`
- `crash_stack.txt`
- 最近日志
- 最近一次成功的 `frame_report.json`
- 最近一次成功的 `world_summary.json`

### 14.2 设计原则

- 崩溃路径只能做最少工作
- 不要在 signal handler 中尝试复杂 JSON 序列化
- 复杂快照应该使用“最近成功快照 + 崩溃附加信息”方式拼装

## 15. 模块划分建议

建议新增模块：

- `src/editor/debug/ai_bridge.zig`
  - 快照总入口
- `src/editor/debug/ai_snapshot.zig`
  - 目录创建与文件输出
- `src/editor/debug/ai_world_dump.zig`
  - 世界与资源引用导出
- `src/editor/debug/ai_render_dump.zig`
  - 渲染状态与派生诊断
- `src/editor/debug/ai_ui_dump.zig`
  - UI 窗口与关键控件导出
- `src/editor/debug/ai_command_bridge.zig`
  - 白名单命令处理

建议在 `imgui_bridge.h/.cpp` 中补充：

- 导出所有活跃窗口列表
- 导出当前 hovered/focused window
- 提供一套调试 item rect 采集 API

建议在 `rhi/device.zig` 中补充：

- 完整纹理区域下载接口
- 纹理字节读回接口

## 16. 与现有代码的接入点

### 16.1 快照触发

建议从编辑器层触发，而不是从底层 RHI 触发。

可选触发方式：

- `F12`
- 顶部菜单 `Debug -> Capture AI Snapshot`
- 命令桥 `capture_snapshot`

接入点建议在：

- `src/editor/core/layer.zig`
- `src/editor/ui/menu_bar.zig`
- `src/editor/ui/viewport.zig`

### 16.2 世界导出

优先复用：

- `engine.scene.serializeWorldAlloc()`

但需要追加 AI 友好的扁平视图，而不是只输出当前存档格式。

### 16.3 日志导出

直接复用：

- `src/editor/ui/windows/console.zig: snapshot()`

### 16.4 渲染导出

直接复用：

- `RenderGraph.writeExports()`
- `RenderGraph.writeFrameReport()`

并追加：

- 当前 SceneViewport 状态
- 当前 PreparedScene 摘要
- 当前渲染 readiness 状态

### 16.5 UI 导出

主要扩展：

- `src/engine/ui/imgui_bridge.cpp`
- `src/engine/ui/imgui_bridge.h`
- `src/engine/ui/imgui.zig`

## 17. AI 读取顺序规范

为了提高 AI 分析质量，快照包必须建议如下读取顺序：

1. `manifest.json`
2. `integrity_report.json`
3. `frame_report.json`
4. `render_state.json`
5. `world_summary.json`
6. `selection.json`
7. `ui_findings.json`
8. `console.jsonl`
9. `world.json`
10. `ui_windows.json`
11. `ui_items.json`
12. `viewport.png`

理由：

- 先看摘要与异常，再下钻原始数据，AI 的推理成本最低。
- 避免一上来让 AI 淹没在全量 world dump 中。

## 18. 第一版实施范围

第一版必须完成：

- 快照目录输出
- `manifest.json`
- `world.json`
- `world_summary.json`
- `selection.json`
- `viewport_state.json`
- `window_state.json`
- `render_graph.json`
- `frame_report.json`
- `render_state.json`
- `console.jsonl`
- `integrity_report.json`

第一版可以暂缓：

- `viewport.png`
- `ui_items.json`
- 命令桥
- 崩溃捕获

但 `ui_windows.json` 建议尽早做，因为 UI 调试是当前项目的高频痛点。

## 19. 第二版实施范围

第二版补齐：

- `viewport.png`
- `ui_windows.json`
- `ui_items.json`
- `ui_findings.json`
- 本地命令文件桥
- `command_log.jsonl`

## 20. 第三版实施范围

第三版再考虑：

- 本地 HTTP 或 socket 桥
- 崩溃堆栈导出
- 更深层 GPU 资源截图
- 自动重放脚本

## 21. 最终判断

对于当前 Guava Engine，真正能让 AI 看懂问题的，不是“立刻做一个远程 HTTP 调试器”，而是把已有调试信息收敛成一套稳定、去歧义、可分享、可下钻的快照格式。

只要 Snapshot Layer 与 UI Inspector Layer 做对，AI 就已经能显著帮助以下问题：

- 为什么实体不显示
- 为什么选取不准
- 为什么材质引用缺失
- 为什么视口没有图像
- 为什么某个窗口布局错乱
- 为什么按钮点不到
- 为什么当前渲染链路没有产生 draw item

在这之后，再引入受控命令桥，AI 才能进一步从“读懂”进入“协助试错与修复”。
