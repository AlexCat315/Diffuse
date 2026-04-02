# Guava Engine — MISSING ITEMS（统一缺失与生产计划）

> 目标：将"生产级计划"与 `GUAVA_ENGINE.md` 中**所有未完成项**统一收敛到此文档。
> 最后更新：2026-04-02
> 维护原则：
> - 本文件是缺失项唯一清单（Single Source of Truth）
> - `GUAVA_ENGINE.md` 保留架构说明与阶段叙事，缺失项状态以本文件为准
> - 已完成项收归 §0 归档；正文只保留**未完成**条目

---

## 0. 已完成归档

> 折叠区：仅记录"做了什么 + 验证日期"，不再占据正文视觉空间。

<details><summary>展开已完成项（点击）</summary>

| 完成日期 | 条目 |
|----------|------|
| — | GR-2 多场景基础闭环：SceneManager / async scene read / `DontDestroyOnLoad` / 脚本 API 桥接 |
| — | GR-2 回归测试覆盖：场景路径解析、回调、持久对象保留、unload 行为 |
| — | GR-1 音频 bus 与 Inspector 路由能力 |
| — | 材质系统 Phase-1 与部分 Phase-2 底座（`MaterialAst`/`MaterialGraph`） |
| 2026-04-01 | GR-2 生产化收尾：`TransitionKind.stream` / `requestStreamScene` / errdefer 快照恢复；viewport phase 标签+进度条 |
| 2026-04-01 | Player-only 验证：`player_main.zig` 独立入口 + `build.zig` player/run-player 步骤 |
| 2026-04-01 | `zig build package` macOS .app bundle（binary + SDL3 dylib + assets + rpath 改写） |
| 2026-04-02 | `zig build cook` 通过 engine validate 刷新 derived 产物（7434 文件已验证） |
| 2026-04-02 | `zig build scripts` 编译 WASM + NativeAOT，产物打包到 `Contents/scripts/` |
| 2026-04-01 | player-only 二进制裁剪：`player_main.zig` 不引入 editor 模块 |
| 2026-04-01 | macOS app bundle：`zig-out/package/GuavaGame.app/` 含 Info.plist、Frameworks/libSDL3、assets/ |
| 2026-04-02 | Windows/Linux 目录结构布局代码（待目标平台测试） |
| 2026-04-02 | `build_manifest.json`（SHA256 × 全部打包文件，LC_ALL=C 排序） |
| 2026-04-01 | Editor 与 Player 启动入口完全分离 |
| 2026-04-01 | Player 运行时依赖隔离检查通过 |
| 2026-04-01 | `PlayerBootstrapLayer` on_attach 加载 start_scene |
| 2026-04-01 | SceneManager errdefer 快照恢复 + `failTransition` 统一错误路径 |
| 2026-04-01 | M1 验收：`zig build run-player` 启动并加载 start_scene |
| — | C# 与 WASM 职责边界确立（gameplay vs plugin） |

</details>

---

## 1. P0 — 游戏运行时基础（阻断项）

> 不完成就无法"一键运行一个可玩游戏"。按依赖顺序排列。

### 1.1 Play Mode / GameState（GR-3）⭐ 最高优先
+ [x] `Editor / Playing / Paused / Stopped` 状态机完善（已有 `playback_session.zig` 基础骨架）
+ [x] Play 时克隆场景、Stop 时恢复（已有 snapshot 机制，需验证完整性）
+ [x] `Time.deltaTime` / `Time.timeScale` 统一语义（`delta_seconds * time_scale`，已在 `application.zig` 修复）
+ [x] 固定步长物理 + 渲染帧插值隔离

验收：Play/Stop 反复切换无状态泄漏，场景稳定回滚

### 1.2 启动生命周期
+ [x] 标准化：Boot → Mount → Scene Load → Game Loop → Shutdown
+ [ ] player-only 自动化 smoke test

验收：Player 模式不加载任何编辑器层，通过 smoke test

### 1.3 输入映射系统（GR-6）
+ [x] Action 映射层（键鼠/手柄统一）— `engine/core/input_action.zig`，含 JSON 持久化
+ [x] 运行时查询 API：`isActionPressed/getAxis` — 已集成到 `ScriptContext`
+ [ ] 编辑器映射配置与重绑定（ImGui 重绑定面板）

验收：键盘 + 手柄可映射到同一 action 且可重绑定

### 1.4 物理脚本宿主 API（GR-4）
+ [x] `raycast/overlap` 脚本接口 — 已在 `ScriptContext` 暴露
+ [x] Trigger / Collision 回调通路 — `vm_interface.zig` vtable 扩展 + `application.zig` 派发循环

验收：脚本可完成射击检测、触发区、碰撞响应

### 1.5 游戏内 UI（GR-7）
+ [x] Canvas 体系（分辨率自适应）— `engine/runtime_ui/canvas.zig`（scale_to_fit / constant_pixel_size）
+ [x] 运行时控件（Button/Text/Image/Progress）— `engine/runtime_ui/widget.zig` + `canvas.zig` 工厂方法
+ [x] UI 事件系统（阻止点击穿透）— `processPointerEvent()` 逆序命中测试，`blocks_pointer` 标志
+ [x] 脚本 UI 宿主 API — `ScriptContext.uiAddText/uiAddButton/uiSetProgress/uiClear` 等方法

验收：菜单/HUD/血条可在 player 中稳定运行

---

## 2. P1 — Sequencer 与影视创作管线

> 统一 Sequencer 模型：不做"游戏模式 vs 影视模式"，而是让 Sequencer 成为游戏过场与影视渲染共用的脊柱。
> 设计详情见 [附录 A](#附录-a统一-sequencer-架构设计)。

### 2.1 Sequence 数据模型 + 资产类型
- [ ] `engine/cinematic/` 模块：`sequence.zig` / `track.zig` / `keyframe.zig` / `evaluator.zig` / `camera_path.zig`
- [ ] `.guava_sequence` 资产格式（JSON，含 camera_path / animation / audio / event / property 轨道）
- [ ] Evaluator：给定时间 t → 求值所有轨道 → 驱动 World
- [ ] Camera Path 插值（Bézier / Catmull-Rom）

### 2.2 Sequencer UI 面板
- [ ] 主面板：时间刻度尺 + 轨道列表 + 播放头（基于 `animation_editor.zig` 扩展）
- [ ] 轨道行 UI：彩色条 + 关键帧菱形 + 拖拽
- [ ] 关键帧属性编辑面板
- [ ] Easing 曲线可视化编辑器
- [ ] 3D Viewport 中相机路径样条 Gizmo

### 2.3 离线渲染管线增强
- [ ] Sequencer 驱动的 RenderOutputJob 模式（`evaluate(frame/fps)` → 路径追踪 → 导出）
- [ ] Render Queue 面板（选择 Sequence + 渲染配置，批量排队）
- [ ] FFmpeg 视频编码输出（H.264/H.265/ProRes）
- [ ] EXR 序列输出完善

### 2.4 游戏内序列触发 API
- [ ] 运行时 `world.loadSequence()` / `seq.play()` / `seq.onComplete()` 接口
- [ ] 过场动画 = Sequence 在游戏运行时播放；影视渲染 = 同一 Sequence 在 Render Queue 离线渲染

---

## 3. P1 — 核心引擎能力

> 可做 demo 但不可稳定交付。

### 3.1 导航寻路（GR-5）
- [ ] Recast/Detour 集成
- [ ] NavMesh bake 与可视化
- [ ] Agent 避障

### 3.2 存档系统
- [ ] 游戏状态序列化（排除纯运行时噪声字段）
- [ ] 存档槽位与元数据
- [ ] 快速存读档

### 3.3 脚本调试器
- [ ] C#/WASM 调试适配（断点/单步/变量/调用栈）

### 3.4 性能分析体系
- [ ] CPU/GPU profiler、frame timeline、内存追踪、drawcall 分析

---

## 4. P2 — 内容工具链与渲染增强

### 4.1 材质与内容工具
- [ ] CT-3 节点材质编辑器 Phase-2（节点图 UI + 双后端编译）
- [ ] CT-7 UV 编辑器
- [ ] CT-6 面光源（raster + PT 一致）
- [ ] CT-8 LookDev 模式增强

### 4.2 渲染增强
- [ ] R-7 SSR 粗糙度感知模糊
- [ ] R-9/R-10/R-11 渲染风格插件化系统收尾

---

## 5. P2 — 发布运维与构建管线

### 5.1 构建管线深化
- [ ] BuildGraph：代码、脚本、资源统一 DAG
- [ ] 增量构建与缓存（指纹 + 依赖）
- [ ] 脚本产物稳定化（ABI/versioning）

### 5.2 发布运维
- [ ] 平台打包签名（Mac 签名 / Windows MSIX / Linux AppImage）
- [ ] 符号分离与崩溃收集（minidump）
- [ ] 自动版本回滚
- [ ] 差量补丁（chunk/manifest）

---

## 6. P2 — AI-Native 与插件系统

### 6.1 MCP 与 AI 工具链
- [ ] AI-1 Command 扩展（材质/渲染/动画域）
- [ ] AI-2 三层 API（Scene/Asset/Render）
- [ ] AI-3 截图反馈闭环
- [ ] AI-4 Ghost Highlight

### 6.2 In-Memory MCP 双轨架构
- [ ] 下沉 ToolBridge/SnapshotStore 到引擎核心
- [ ] stdio 与内存通道统一抽象
- [ ] lazy sync（按需快照）
- [ ] `ai_chat` 与外部 MCP client 共用同一协议栈

### 6.3 脚本分层（GR-8）
- [ ] 编辑器中 scripts/plugins 独立加载与调试入口
- [ ] IDE 一键跳转与工具链完整打通

---

## 7. P3 — 平台与后端

- [ ] RHI-4 DX12 backend 补齐（Windows 目标态落地）
- [ ] Vulkan 路径完整性验证（不仅是可编译骨架）
- [ ] RT 路径跨平台一致性（非 Metal 平台）

---

## 8. 架构冻结检查清单

> 在大规模实施前执行，冻结接口避免返工。

- [ ] 运行模式冻结：Editor / Player / Tooling
- [ ] 模块依赖白名单（Player 禁 editor 依赖）
- [ ] 资源契约冻结：源格式、cook 格式、manifest 版本策略
- [ ] 架构 RFC（依赖图 + 禁止依赖规则）
- [ ] 资源格式与版本兼容规范

---

## 9. 里程碑验收标准

| 里程碑 | 条件 | 状态 |
|--------|------|------|
| M1 可运行 | 单命令启动 player，进入 start scene | ✅ 2026-04-01 |
| M2 可打包 | 单命令产出可分发包，目标平台可启动 | ⬜ |
| M3 可回滚 | 发布失败可自动回滚到上一版本 | ⬜ |
| M4 可定位 | 崩溃后可符号化到函数与源码位置 | ⬜ |
| M5 可持续迭代 | 增量构建可控，核心回归自动化覆盖 | ⬜ |

---

## 附录 A：统一 Sequencer 架构设计

> 此节为设计参考，可操作条目已提取到 §2。

### 核心思想

不是做两个模式，而是让 Sequencer 成为游戏和影视共用的脊柱。

```
┌─────────────────────────────────────────────────────────────┐
│                    Guava Editor                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Viewport (不变)                          │   │
│  │    Play/Pause/Stop = 全局模拟控制                     │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           Sequencer (新增核心面板)                     │   │
│  │  ┌─ 时间尺  0s ──── 5s ──── 10s ──── 15s ────┐      │   │
│  │  │  🎥 Camera Track   ●────●────●              │      │   │
│  │  │  🦴 Anim: Walk     ▓▓▓▓▓▓▓▓                │      │   │
│  │  │  🦴 Anim: Run            ▓▓▓▓▓▓▓▓          │      │   │
│  │  │  🔊 Audio: BGM     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓     │      │   │
│  │  │  ⚡ Event: Spawn         ●                  │      │   │
│  │  │  📜 Script: Effect              ●───●       │      │   │
│  │  └────────────────────────────────────────────┘      │   │
│  │  [◀] [▶ Play] [⏸] [◼ Stop] [🔴 Record] │ 30fps │     │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Sequencer vs Viewport Play：正交的两套时钟

| | Viewport Play | Sequencer Play |
|---|---|---|
| 驱动内容 | 物理 + 脚本 + AI 全部推进 | 只推进时间线上的轨道 |
| 用途 | 游戏运行时 | 影视预览 / 过场动画编辑 |
| 可同时激活 | ✅ 游戏运行中触发过场序列 | ✅ |

### UE 经验对照

| UE 的经验 | Guava 的对应 |
|-----------|-------------|
| Level Sequence 既用于过场动画也用于游戏内脚本触发 | Guava 的 Sequence 资产同理 |
| Play 按钮 = 模拟，Sequencer Play = 时间轴驱动 | Viewport Play = 模拟，Sequencer Play = 时间轴 |
| Movie Render Queue 离线渲染 | 已有 RenderOutputJob（PNG/EXR 序列导出）直接复用 |

### 引擎模块结构

```
engine/cinematic/
├── sequence.zig          # Sequence 资产：轨道列表 + 时长 + 帧率
├── track.zig             # Camera / Animation / Audio / Event / Property
├── keyframe.zig          # time + value + easing curve
├── evaluator.zig         # 给定时间 t → 求值所有轨道 → 驱动 World
└── camera_path.zig       # Bézier / Catmull-Rom 路径插值
```

### Sequence 资产格式 (.guava_sequence)

```json
{
  "name": "Opening Cinematic",
  "fps": 30,
  "duration": 15.0,
  "tracks": [
    {
      "type": "camera_path",
      "target": "CinematicCamera",
      "keyframes": [
        { "time": 0.0, "position": [0,5,-10], "look_at": [0,1,0], "fov": 45, "easing": "ease_in_out" },
        { "time": 5.0, "position": [5,3,-5],  "look_at": [0,1,0], "fov": 60, "easing": "linear" }
      ]
    },
    {
      "type": "animation",
      "target": "Character",
      "clip": "assets/animations/walk.gltf",
      "start_time": 0.0, "end_time": 5.0, "blend_in": 0.2
    },
    {
      "type": "property",
      "target": "Sun",
      "property": "intensity",
      "keyframes": [
        { "time": 0.0, "value": 1.0 },
        { "time": 10.0, "value": 0.3, "easing": "ease_out" }
      ]
    }
  ]
}
```

### 编辑器 UI 结构

```
editor/ui/panels/tools/sequencer/
├── sequencer_panel.zig     # 主面板：时间尺 + 轨道列表 + 播放头
├── timeline_ruler.zig      # 时间刻度尺 + 帧编号
├── track_row.zig           # 每条轨道的 UI 行
├── keyframe_editor.zig     # 关键帧属性面板
├── curve_editor.zig        # easing 曲线可视化
└── camera_path_gizmo.zig   # 3D 视口相机路径样条
```

---

## 附录 B：与 `GUAVA_ENGINE.md` 的关系

- `GUAVA_ENGINE.md`：保留架构、阶段叙事、方案说明。
- `MISSING_ITEMS.md`（本文件）：仅维护"未完成项 + 优先级 + 验收标准"。
- 完成时：移入 §0 归档并补验证日期；`GUAVA_ENGINE.md` 仅更新结果摘要。
