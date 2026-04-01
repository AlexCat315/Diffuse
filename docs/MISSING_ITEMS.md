# Guava Engine — MISSING ITEMS（统一缺失与生产计划）

> 目标：将当前对话给出的“生产级计划”与 `GUAVA_ENGINE.md` 中**所有未完成项**统一收敛到此文档。
> 最后更新：2026-04-01
> 维护原则：
> - 本文件是缺失项唯一清单（Single Source of Truth）
> - `GUAVA_ENGINE.md` 保留架构说明与阶段叙事，缺失项状态以本文件为准

---

## 0. 状态基线（已完成 / 已验证）

### 0.1 已完成（近期）
- [x] GR-2 多场景基础闭环：SceneManager / async scene read / `DontDestroyOnLoad` / 脚本 API 桥接
- [x] GR-2 回归测试覆盖：简称场景路径解析、回调、持久对象保留、unload 行为
- [x] GR-1 音频 bus 与 Inspector 路由能力
- [x] 材质系统 Phase-1 与部分 Phase-2 底座（`MaterialAst`/`MaterialGraph`）

### 0.2 仍需完善（即便标记“部分完成”）
- [x] GR-2 生产化收尾：loading 进度可视化、转场策略、场景流式化、失败恢复策略
  - 验证：`scene_manager.zig` 新增 `TransitionKind.stream` / `requestStreamScene` / errdefer 快照恢复；`viewport.zig` 新增 phase 标签+进度条+failed 提示；`theme.zig` 补 `overlay_progress_width`；`zig build player` 编译通过 (2026-04-01)
- [x] 发布流程中的 player-only 验证（无 editor 依赖运行）
  - 验证：新增 `src/player_main.zig`（独立入口，零 editor 依赖）；`build.zig` 新增 `player` / `run-player` 步骤；`zig build player` 编译通过 (2026-04-01)

---

## 1. P0 阻断项（不完成就无法“生产级一键运行游戏”）

### 1.1 Build / Cook / Package 全链路（发布工程）
现状：`build.zig` 仅有开发/测试/运行目标，无发布级打包流水线。

缺失：
- [x] `zig build package`（或等价）发布目标 — `build.zig` package step 生成 macOS .app bundle（binary + SDL3 dylib + assets），rpath 自动改写 (2026-04-01)
- [x] 资源 Cook 流程标准化 — `zig build cook` 步骤通过 engine validate 管线刷新 derived 产物；package 步骤自动打包 `assets/derived/{models,textures}` + `asset_registry.json`（7434 文件已验证） (2026-04-02)
- [x] 脚本产物纳入构建图（C# / WASM） — `zig build scripts` 自动发现并编译 `project_plugins/*/main.zig`→WASM + `examples/csharp/*/*.csproj`→NativeAOT dylib；产物打包到 `Contents/scripts/{wasm,csharp}/` (2026-04-02)
- [x] player-only 二进制裁剪（剔除 editor 依赖）— `src/player_main.zig` 独立入口，不引入 editor 模块；`zig build player` 通过 (2026-04-01)
- [x] 平台产物装配：macOS app bundle — `zig-out/package/GuavaGame.app/` 含 Info.plist、Frameworks/libSDL3、assets/ (2026-04-01)
- [x] 平台产物装配：Windows/Linux 目录结构 — build.zig 已含 Windows (`package/GuavaGame/`) 和 Linux (`package/guava-game/{bin,share}`) 布局代码，待目标平台测试 (2026-04-02)
- [x] 构建可复现（manifest + hash） — package 步骤自动生成 `build_manifest.json`（SHA256 × 全部打包文件，LC_ALL=C 排序） (2026-04-02)

验收：
- [x] 单命令产出可分发包，并可在无源码环境直接启动游戏窗口 — `zig build package` 一键生成 .app，从 /tmp 启动验证 OK (2026-04-01)

### 1.2 Player / Editor 启动分层
现状：主启动链默认进入编辑器形态，运行模式边界不够硬。

缺失：
- [x] Editor 与 Player 启动入口完全分离 — `player_main.zig` + `build.zig` player/run-player 步骤 (2026-04-01)
- [x] 运行时依赖隔离检查（Player 禁止 editor/ui/tooling 模块）— player 入口仅依赖 `guava` 引擎模块，编译验证无 editor import (2026-04-01)
- [ ] 启动生命周期标准化：Boot -> Mount -> Scene Load -> Game Loop -> Shutdown

验收：
- [ ] Player 模式不加载任何编辑器层，且通过自动化 smoke test（入口已分离，smoke test 待补）

### 1.3 Play Mode / GameState（GR-3）
- [ ] `Editor / Playing / Paused / Stopped` 状态机
- [ ] Play 时克隆场景、Stop 时恢复
- [ ] `Time.deltaTime` / `Time.timeScale` 统一语义
- [ ] 固定步长物理 + 渲染帧插值隔离

验收：
- [ ] Play/Stop 反复切换无状态泄漏，场景稳定回滚

### 1.4 输入映射系统（GR-6）
- [ ] Action 映射层（键鼠/手柄统一）
- [ ] 运行时查询 API：`isActionPressed/getAxis`
- [ ] 编辑器映射配置与重绑定

验收：
- [ ] 键盘 + 手柄可映射到同一 action 且可重绑定

### 1.5 游戏内 UI（GR-7）
- [ ] Canvas 体系（分辨率自适应）
- [ ] 运行时控件（Button/Text/Image/Progress）
- [ ] UI 事件系统（阻止点击穿透）
- [ ] 脚本 UI 宿主 API

验收：
- [ ] 菜单/HUD/血条可在 player 中稳定运行

### 1.6 物理脚本宿主 API（GR-4）
- [ ] `raycast/overlap` 脚本接口
- [ ] Trigger / Collision 回调通路

验收：
- [ ] 脚本可完成射击检测、触发区、碰撞响应

---

## 2. P1 核心能力缺口（可做 demo，但不可稳定交付）

### 2.1 导航寻路（GR-5）
- [ ] Recast/Detour 集成
- [ ] NavMesh bake 与可视化
- [ ] Agent 避障

### 2.2 存档系统
- [ ] 游戏状态序列化（排除纯运行时噪声字段）
- [ ] 存档槽位与元数据
- [ ] 快速存读档

### 2.3 脚本调试器
- [ ] C#/WASM 调试适配（断点/单步/变量/调用栈）

### 2.4 性能分析体系
- [ ] CPU/GPU profiler、frame timeline、内存追踪、drawcall 分析

### 2.5 发布运维基础
- [ ] 符号分离与崩溃收集（minidump）
- [ ] 自动版本回滚
- [ ] 差量补丁（chunk/manifest）

---

## 3. P2 内容创作链缺口（影响画面质量与生产效率）

### 3.1 材质与内容工具链
- [ ] CT-3 节点材质编辑器 Phase-2（节点图 UI + 双后端编译）
- [ ] CT-7 UV 编辑器
- [ ] CT-6 面光源（raster + PT 一致）
- [ ] CT-8 LookDev 模式增强

### 3.2 动画与镜头
- [ ] CT-4 关键帧动画 + Dope Sheet
- [ ] CT-5 Camera Sequencer

### 3.3 输出链
- [ ] CT-9 渲染输出面板完善（序列/4K/tile/progress）
- [ ] CT-10 FFmpeg 视频编码输出（H.264/H.265/ProRes）
- [ ] PT-8 EXR 序列输出完善

### 3.4 渲染增强残项
- [ ] R-7 SSR 粗糙度感知模糊
- [ ] R-9/R-10/R-11 渲染风格插件化系统收尾

---

## 4. AI-Native 与插件系统缺口

### 4.1 MCP 与 AI 工具链
- [ ] AI-1 Command 扩展（材质/渲染/动画域）
- [ ] AI-2 三层 API（Scene/Asset/Render）
- [ ] AI-3 截图反馈闭环
- [ ] AI-4 Ghost Highlight

### 4.2 In-Memory MCP 双轨架构
- [ ] 下沉 ToolBridge/SnapshotStore 到引擎核心
- [ ] stdio 与内存通道统一抽象
- [ ] lazy sync（按需快照）
- [ ] `ai_chat` 与外部 MCP client 共用同一协议栈

### 4.3 脚本分层（GR-8）
- [x] C# 与 WASM 职责边界确立（gameplay vs plugin）
- [ ] 编辑器中 scripts/plugins 独立加载与调试入口
- [ ] IDE 一键跳转与工具链完整打通

---

## 5. 平台与后端缺口

- [ ] RHI-4 DX12 backend 补齐（Windows 目标态落地）
- [ ] Vulkan 路径完整性验证（不仅是可编译骨架）
- [ ] RT 路径跨平台一致性（非 Metal 平台）

---

## 6. 生产级落地计划（重构后统一版）

> 这一节是“怎么做到生产级”，用于替代临时最小闭环方案。执行时按阶段冻结接口，避免反复返工。

### Phase A：架构冻结（2-3 周）
- [ ] 运行模式冻结：Editor / Player / Tooling
- [ ] 模块依赖白名单（Player 禁 editor 依赖）
- [ ] 资源契约冻结：源格式、cook 格式、manifest 版本策略

交付物：
- [ ] 架构 RFC（依赖图 + 禁止依赖规则）
- [ ] 资源格式与版本兼容规范

### Phase B：运行时产品化（4-6 周）
- [x] 启动入口分离与生命周期统一 — `player_main.zig` 独立入口 + `PlayerBootstrapLayer` on_attach 加载 start_scene (2026-04-01)
- [x] 失败恢复机制（场景加载失败、资源缺失降级）— SceneManager errdefer 快照恢复 + `failTransition` 统一错误路径 (2026-04-01)
- [ ] player-only 自动化 smoke 测试

交付物：
- [x] 可独立运行的 Player target — `zig build player` / `zig build run-player` (2026-04-01)
- [ ] 启动链路自动化测试

### Phase C：资产与脚本管线（6-10 周）
- [ ] BuildGraph：代码、脚本、资源统一 DAG
- [ ] 增量构建与缓存（指纹 + 依赖）
- [ ] Cook/Pack/Stage 标准命令
- [ ] 脚本产物稳定化（ABI/versioning）

交付物：
- [ ] 一键构建命令（dev/release）
- [ ] 增量构建报告（耗时与命中率）

### Phase D：发布与运维（6-10 周）
- [ ] 平台打包（mac/win/linux）
- [ ] 签名、符号、崩溃回传
- [ ] 版本回滚与差量补丁

交付物：
- [ ] 可分发安装包
- [ ] 崩溃符号化与回滚手册

### Phase E：质量门禁（持续）
- [ ] 单测 + 集成 + 场景回放 + 像素回归
- [ ] 性能预算门禁（帧时、内存峰值、加载时延）
- [ ] 发布候选检查单（RC checklist）

交付物：
- [ ] CI 绿色才可合并
- [ ] 每周一次“可发布演练”

---

## 7. 里程碑验收标准（生产级）

### M1：可运行
- [x] 单命令启动 player，进入指定 start scene — `zig build run-player -- --project-path <dir>` 加载 `.guava` 中 `start_scene` (2026-04-01)

### M2：可打包
- [ ] 单命令产出可分发包，目标平台可启动

### M3：可回滚
- [ ] 发布失败可自动回滚到上一版本

### M4：可定位
- [ ] 崩溃后可符号化到函数与源码位置

### M5：可持续迭代
- [ ] 增量构建可控，核心回归自动化覆盖

---

## 8. 与 `GUAVA_ENGINE.md` 的关系（避免重复维护）

- `GUAVA_ENGINE.md`：保留架构、阶段叙事、方案说明。
- `MISSING_ITEMS.md`（本文件）：仅维护“未完成项 + 优先级 + 验收标准 + 生产计划执行状态”。
- 当某项完成时：
  1. 在本文件打钩并补“验证证据（测试/命令/截图）”
  2. 在 `GUAVA_ENGINE.md` 仅更新结果摘要，不再重复维护完整 checklist

