# Guava Engine — 缺失项清单

> **目标**: 列出阻碍"有效开发游戏"的所有缺失项，按对 gameplay 的影响程度排序
> **上次更新**: 2026-04-01
> **前置文档**: `GUAVA_ENGINE.md`（引擎架构）、`HYBRID_RENDERER_UPGRADE.md`（渲染升级路线）

---

## 一、致命缺失（没有这些就无法做游戏）

### 1. 没有 Play Mode（GR-3）

**现状**: 编辑器就是运行时，没有"编辑态"和"游戏态"的切换。

**缺失内容**:
- [ ] `GameState` 状态机: Editor / Playing / Paused / Stopped
- [ ] Play 时克隆场景，Stop 时恢复（与 Unity Play Mode 一致）
- [ ] `Time.deltaTime` / `Time.timeScale` 供脚本使用
- [ ] 固定步长物理与变帧率渲染的分离（Jolt 60Hz + 渲染插值）

**影响**: 无法在编辑器内测试游戏。开发者必须构建后运行才能验证逻辑，迭代周期从秒级变成分钟级。

**文档位置**: `GUAVA_ENGINE.md` 第八节 GR-3，全部为 `[ ]`

---

### 2. 没有游戏内 UI 系统（GR-7）

**现状**: ImGui 仅用于编辑器，没有任何运行时游戏 UI。

**缺失内容**:
- [ ] Canvas 组件（分辨率自适应）
- [ ] 基础控件: Button / Text / Image / ProgressBar / 九宫格拉伸
- [ ] UI 事件系统（射线 vs UI 碰撞，阻止穿透到游戏世界）
- [ ] 脚本宿主绑定: `ui.createButton("Start")` / `ui.setText(id, "HP: 100")`
- [ ] 字体渲染（字体图集、多语言文本、文本网格）

**影响**: 无法做主菜单、HUD、血条、对话框、暂停菜单。任何游戏都需要 UI。

**代码状态**: `src/engine/ui/` 只有 ImGui 绑定，零运行时 UI 代码

---

### 3. 没有输入映射系统（GR-6）

**现状**: SDL3 原始按键事件直接暴露，没有 Action 抽象层。

**缺失内容**:
- [ ] Action → Key/Gamepad 映射表（JSON 配置）
- [ ] `input.isActionPressed("jump")` / `input.getAxis("move_x")`
- [ ] 手柄支持（扳机轴、摇杆死区、震动反馈）
- [ ] 编辑器中可视化映射编辑面板
- [ ] 运行时重绑定（Rebinding）支持

**影响**: 脚本只能读原始键码（`Key.Space`），无法做"空格键和手柄 A 键都触发 jump"的抽象。每个游戏都要自己写映射逻辑。

**代码状态**: `src/engine/core/input.zig` 只有键状态查询，无 Action 系统

---

### 4. 没有物理脚本 API（GR-4）

**现状**: Jolt Physics 已集成，但脚本层无法调用。

**缺失内容**:
- [ ] `physics.raycast(origin, direction, maxDist) -> HitInfo`
- [ ] `physics.overlapSphere(center, radius) -> []Entity`
- [ ] `physics.overlapAABB(min, max) -> []Entity`
- [ ] `TriggerEnter` / `TriggerExit` / `TriggerStay` 回调到脚本层
- [ ] `CollisionEnter` / `CollisionExit` 回调到脚本层

**影响**: 脚本无法做射击检测、拾取判定、区域触发。物理引擎存在但游戏逻辑用不上。

**代码状态**: `src/engine/physics/system.zig` 有 raycast/overlap/sweep 实现，但未暴露给 ScriptContext

---

### 5. 没有导航寻路（GR-5）

**现状**: 零实现。

**缺失内容**:
- [ ] 集成 Recast/Detour
- [ ] NavMesh 从场景 static mesh 烘焙
- [ ] Agent 组件: 自动寻路 + 避障
- [ ] 编辑器可视化 NavMesh 覆盖层
- [ ] 动态障碍物更新（门开关、桥升降）

**影响**: AI 角色无法移动。任何有 NPC/敌人的游戏都需要寻路。

**代码状态**: 零文件。`build.zig` 无 Recast 依赖，`third_party/` 无相关代码

---

### 6. 没有多场景管理（GR-2）

**现状**: 单场景工作，无法切换关卡。

**缺失内容**:
- [ ] `SceneManager.loadScene("level_2")` / `unloadScene()`
- [ ] 异步加载 + 加载界面回调
- [ ] 全局不销毁对象标记 (`DontDestroyOnLoad`)
- [ ] 场景过渡动画/淡入淡出
- [ ] 加载进度查询（用于 loading screen）

**影响**: 无法做主菜单 → 游戏关卡 → 结算画面的流程。

**代码状态**: `src/engine/scene/scene_manager.zig` 存在场景过渡框架，但未验证游戏运行时可用性

---

## 二、严重缺失（有了能做游戏，但体验很差）

### 7. 没有性能分析工具

**现状**: 状态栏只有一个 FPS 数字。

**缺失内容**:
- [ ] **GPU Profiler**: 逐 Pass 耗时分析，类似 RenderDoc 的 timeline
- [ ] **CPU Profiler**: 脚本/物理/音频/渲染各自的帧耗时
- [ ] **Frame Timeline**: 可视化一帧内各子系统执行顺序和耗时
- [ ] **内存 Profiler**: 分配追踪、峰值统计、泄漏检测
- [ ] **Draw Call Analyzer**: 按材质/网格分组统计

**影响**: 游戏卡了不知道是脚本慢了、物理重了、还是渲染爆了。只能盲猜。

**代码状态**: `src/engine/rhi/device.zig:512` 明确标注 "stub - kept for compatibility"

---

### 8. 没有脚本调试器

**现状**: 脚本编辑器有断点 UI 框架，但没有调试后端。

**缺失内容**:
- [ ] WASM 调试协议支持（WAMR debug）
- [ ] C# 调试适配器（DAP 协议）
- [ ] 断点命中暂停执行
- [ ] 单步执行（Step Over / Step Into / Step Out）
- [ ] 变量监视窗口
- [ ] 调用栈查看

**影响**: 脚本 bug 只能靠 `log()` 定位。复杂逻辑几乎无法调试。

**代码状态**: `src/editor/ui/panels/tools/script_editor.zig` 有 `breakpoints` / `current_debug_line` / `is_debugging` 字段，但全部未接线

---

### 9. 没有打包发布系统

**现状**: `build.zig` 只有开发和测试目标，无打包目标。

**缺失内容**:
- [ ] `zig build package` 构建目标
- [ ] 运行时二进制裁剪（不含编辑器代码）
- [ ] 资源打包（场景/模型/纹理/音频/脚本产物）
- [ ] macOS: `.app` bundle + codesign + notarization
- [ ] Windows: `.exe` + 资源目录
- [ ] Linux: 可执行文件 + 资源目录
- [ ] 着色器预编译打包

**影响**: 游戏做完了无法发给别人玩。

**代码状态**: `build.zig` 只有 `run` / `run-engine` / `run-launcher` / `test` / `render-test` / `shaders` / `compile-commands`

---

### 10. 没有存档系统

**现状**: 场景序列化存在（JSON v6），但没有游戏状态存档。

**缺失内容**:
- [ ] 游戏状态序列化（排除运行时组件如 Rigidbody 速度）
- [ ] 存档槽位管理
- [ ] 存档缩略图（截图 + 元数据）
- [ ] 快速存档/快速读档
- [ ] 云存档接口（可选）

**影响**: 玩家无法保存进度。

---

### 11. 没有关键帧动画系统（CT-4）

**现状**: 有 Animator 播放 glTF 动画，但没有属性关键帧。

**缺失内容**:
- [ ] 任意 float / vec3 属性可设置关键帧（Transform、Light Intensity、Camera FOV 等）
- [ ] 插值类型: Linear / Bezier / Step
- [ ] Timeline UI: 菱形关键帧标记、拖动、框选
- [ ] 播放控制: Play / Pause / 帧步进 / 跳转
- [ ] Dope Sheet 首版: 按对象和属性分组列出关键帧

**影响**: 无法做相机飞行动画、门开关动画、灯光渐变。只能依赖 glTF 预烘焙动画。

---

### 12. 没有 Camera Sequencer（CT-5）

**现状**: 零实现。

**缺失内容**:
- [ ] 多相机: 场景中放置多个 Camera 实体
- [ ] Shot Track: 时间线上分段标记使用哪个 Camera
- [ ] 镜头切换: Cut / Hold / Blend
- [ ] 按 Sequencer 相机顺序导出帧序列

**影响**: 无法做过场动画、多镜头演示、镜头切换演出。

---

## 三、重要缺失（影响内容品质和开发效率）

### 13. 没有节点材质编辑器（CT-3 Phase 2）

**现状**: `MaterialAst` 数据结构存在，但节点编辑器 UI 是空壳。

**缺失内容**:
- [ ] 节点系统: PBR 参数节点 → 输出节点
- [ ] 内置节点: Texture Sample, Color, Float, Mix, Normal Map, Noise, Voronoi
- [ ] 编译为光栅 Uber Shader 参数图 + Path Tracer BSDF 闭包
- [ ] 实时预览

**影响**: 只能用参数面板调材质，无法做程序化材质、多层混合、复杂效果。

**代码状态**: `src/editor/ui/panels/tools/node_editor.zig` 的 `drawNodeEditor()` 是空 stub，所有参数 `_ =` 丢弃

---

### 14. 没有 UV 编辑器（CT-7）

**现状**: 零实现。UV 只能从 glTF 导入。

**缺失内容**:
- [ ] 独立 2D UV 视图面板
- [ ] 显示当前选中 mesh 的 UV 展开
- [ ] 选择 UV 顶点 / 边 / 面，基础平移 / 旋转 / 缩放
- [ ] 自动 UV 投影: Box / Planar / Cylindrical
- [ ] Checker 预览与 texel density 粗略反馈

**影响**: 导入的模型 UV 有问题无法在引擎内修复。

---

### 15. 没有面光源（CT-6）

**现状**: 只有方向光和点光。

**缺失内容**:
- [ ] 新光源类型: Rectangle / Disk
- [ ] 编辑器表现: 尺寸、方向、颜色、强度、温度
- [ ] 光栅: 近似面光 + soft shadow
- [ ] 路径追踪: 真正面光源采样（NEE）

**影响**: 布光不自然，无法做摄影棚式打光、窗户光、灯管光。

---

### 16. 没有 LookDev 预览模式（CT-8）

**现状**: 视口只有完整渲染模式。

**缺失内容**:
- [ ] 视口着色模式: Solid（无材质）/ Material（有材质）/ Rendered（完整后处理）
- [ ] Matcap / Checker / HDRI 预览开关
- [ ] 选中物体隔离预览
- [ ] Path Trace 预览可降采样 / 限时迭代

**影响**: 无法快速判断是几何问题还是材质问题。

---

### 17. 渲染输出面板不完整（CT-9 部分）

**现状**: 单帧 PNG 导出可用，其余缺失。

**缺失内容**:
- [ ] 帧范围 / 输出格式 EXR / PNG Sequence
- [ ] 降噪开关 / 自适应采样
- [ ] `Render Animation` 一键渲染
- [ ] 进度显示: 当前帧 / 总帧 + 累积 SPP + 预计剩余时间
- [ ] 4K 分 tile 渲染（每 tile 512x512 避免显存溢出）

---

### 18. 没有视频编码（CT-10）

**现状**: 零实现。只能输出单帧图片。

**缺失内容**:
- [ ] FFmpeg 子进程调用封装
- [ ] 支持编码格式: H.264 / H.265 / ProRes
- [ ] 渲染流水线: Path Tracer → EXR → OIDN → Tonemap → FFmpeg
- [ ] 音频混合到视频
- [ ] 输出预设: Web / 4K Cinema / Post-Production

**影响**: 渲染的动画无法导出为视频文件。

---

### 19. VFX 系统极其简陋

**现状**: 只有两种粒子（fountain / orbit），预览是文字而非 3D 视口。

**缺失内容**:
- [ ] GPU 粒子系统
- [ ] 纹理粒子（sprite sheet）
- [ ] 子发射器（Sub-emitters）
- [ ] 粒子碰撞
- [ ] 力场影响
- [ ] 3D 预览视口（当前是文字）
- [ ] 真实曲线编辑器（当前是 3 点线性插值）

**代码状态**: `src/engine/scene/vfx_runtime.zig` 仅 31 行，只定义数据结构。`particle_editor.zig` 预览区只有文字

---

### 20. SSR 粗糙度模糊未完成（R-7）

**现状**: SSR 已接回 HDR 主链，但 roughness-aware blur 未实现。

**缺失内容**:
- [ ] 根据 roughness 对 SSR 结果做 cone tracing / mip blur
- [ ] 光滑表面清晰反射，粗糙表面模糊反射

**影响**: 反射画面不真实，所有表面反射清晰度一致。

---

## 四、平台限制

### 21. Windows/Linux 后端是空壳

**现状**: 只能在 macOS + Metal 上运行。

| 后端 | 状态 |
|------|------|
| Metal | ✅ 可用 |
| Vulkan | ⚠️ `vk_device.zig` 存在但未接入渲染管线 |
| DX12 | ❌ `dx12_device.zig` 是 stub skeleton，所有方法返回 `UnsupportedBackend` |
| RT 后端 | ⚠️ 仅 Metal RT 可用，Windows/Linux 路径为 TODO |

**影响**: 游戏只能跑在 Mac 上。

---

### 22. 没有地形系统

**现状**: 零实现。只有 `PluginType.terrain_gen` 枚举项。

**缺失内容**:
- [ ] 高度图地形
- [ ] 地形 sculpting（升高/降低/平滑）
- [ ] 地形纹理绘制（splat map）
- [ ] 植被散布（grass / trees）
- [ ] LOD 地形（chunk 加载/卸载）

**影响**: 无法做户外场景。

---

## 五、AI-Native 缺失项

### 23. MCP 协议不完整

**现状**: 基础 stdio 协议可用，但功能层缺失。

**缺失内容**:
- [ ] Command 扩展: 材质参数、渲染设置、动画状态
- [ ] Command 增加 `source: enum { human, ai }` 标记
- [ ] MCP 三层 API: Scene API / Asset API / Render API
- [ ] 截图反馈回路（操作后自动截图回传）
- [ ] Ghost Highlight（AI 操作的物体呼吸灯脉冲）
- [ ] In-Memory MCP 双轨架构（当前 stdio 与编辑器割裂）
- [ ] Lazy Sync（当前每帧全局快照拖慢性能）
- [ ] SSE/WebSocket 传输层

---

## 六、Render Graph 缺失

### 24. 瞬态内存别名分配（Transient Memory Aliasing）

**现状**: Render Graph 已计算资源生命周期（first_use / last_use），但未用于内存复用。

**影响**: 15+ Pass、1440p 分辨率下，VRAM 轻松突破 2GB。Mac 统一内存带宽吃紧。

**破局策略**: 基于生命周期的堆栈分配，让无生命周期交集的 Render Target 物理复用同一块显存。

---

## 七、总结：按优先级排序的补齐路线

| 优先级 | 缺失项 | 原因 |
|--------|--------|------|
| **P0** | Play Mode（GR-3） | 没有 Play Mode 就无法在编辑器内测试游戏 |
| **P0** | 游戏内 UI（GR-7） | 任何游戏都需要菜单和 HUD |
| **P0** | 输入映射（GR-6） | 脚本无法处理玩家输入 |
| **P0** | 物理脚本 API（GR-4） | 脚本无法做碰撞检测和触发 |
| **P1** | 性能分析工具 | 卡了不知道原因 |
| **P1** | 脚本调试器 | bug 只能靠 log 定位 |
| **P1** | 多场景管理（GR-2） | 无法做关卡切换 |
| **P1** | 打包发布 | 做完了无法分发 |
| **P1** | 导航寻路（GR-5） | AI 无法移动 |
| **P2** | 关键帧动画（CT-4） | 无法做相机动画 |
| **P2** | 节点材质编辑器（CT-3） | 材质能力受限 |
| **P2** | VFX 系统增强 | 特效能力受限 |
| **P2** | 存档系统 | 无法保存进度 |
| **P2** | 面光源（CT-6） | 布光不自然 |
| **P3** | UV 编辑器（CT-7） | 无法修复导入模型的 UV |
| **P3** | 视频编码（CT-10） | 无法导出视频 |
| **P3** | 地形系统 | 无法做户外场景 |
| **P3** | Vulkan/DX12 后端 | 无法跨平台 |
