# Game Genre Gap Analysis

> 评估 Guava 引擎支持 RTS / 4X / FPS 游戏类型需要补充的系统。
> Generated: 2026-04-08

## 引擎已有能力（可直接使用）

| 系统 | 实现文件 | 能力概述 |
|------|----------|----------|
| 物理 | `src/engine/physics/` | Jolt Physics，Box/Sphere/Capsule/MeshCollider，Rigidbody，约束，射线检测，CharacterController |
| 导航 | `src/engine/navigation/` | Recast NavMesh 烘焙 + Detour 群体寻路（128 agents），NavAgent 组件 |
| 渲染 | `src/engine/render/` | 30+ render pass，PBR/IBL/SSAO/SSGI/SSR/Bloom/TAA/Path Tracing，Cascade Shadow Map |
| 动画 | `src/engine/animation/` | 骨骼动画、状态图、1D/2D 混合空间、多轨图层、交叉淡入 |
| 脚本 | `src/engine/script/` | Zig + C# 热重载，完整 host API，DAP 调试 |
| 音频 | `src/engine/audio/` | SoLoud，3D 空间音频，Master/Music/SFX 总线 |
| 输入 | `src/engine/core/input*.zig` | 键鼠+手柄，Action 映射，JSON 序列化 |
| 资产 | `src/engine/assets/` | GLTF 2.0，Prefab，异步导入，cooked 缓存 |
| 场景 | `src/engine/scene/` | 存档系统（多槽位），场景加载/切换，全局时间缩放 |
| ECS | `src/engine/scene/world.zig` | 21 种组件类型，Transform 层级，空间查询（BVH） |
| 过场 | `src/engine/cinematic/` | 相机路径、关键帧动画、FFMPEG 导出 |
| 运行时 UI | `src/engine/ui/` | 保留模式 Canvas，SDF 字体，Flexbox 布局，点击/悬停交互，Debug HUD |
| C# 脚本 SDK | `sdk/csharp/GuavaEngine/` | NativeAOT .dylib，Canvas/Transform/Input/Time API，完整导出 |
| 插件 | `src/engine/plugin/` | 热加载插件框架（render_style, audio_effect, physics_ext, terrain_gen, ai_behavior, ui_extension, script_vm） |

## 缺失系统清单

### 1. 运行时 UI 系统 ✅ 已完成

**当前状态**: 已实现。保留模式 UI 系统，含 SDF 字体渲染、Flexbox 布局、点击/悬停交互、C# 脚本 API。

**实现文件**:
- `src/engine/ui/style.zig` — 颜色、文本对齐、视觉样式属性
- `src/engine/ui/layout.zig` — Flexbox-lite 布局引擎
- `src/engine/ui/node.zig` — 保留模式节点树（NodePool + Tree）
- `src/engine/ui/renderer.zig` — 批量 UI 四边形渲染（SDF text + filled rect）
- `src/engine/ui/font.zig` — stb_truetype SDF atlas 生成
- `src/engine/ui/canvas.zig` — Canvas 公共 API（createNode/hitTest/processInput/addPanel/addLabel）
- `src/engine/script/host/canvas.zig` — 10 个 host 函数（C# 桥接）
- `sdk/csharp/GuavaEngine/GuavaCanvas.cs` — C# Canvas SDK

**已完成项**:
- [x] Font 渲染（SDF atlas，stb_truetype）
- [x] 矩形图元绘制（filled rect with border_radius）
- [x] 文本布局（左/中/右对齐）
- [x] 交互系统（点击/悬停命中测试，processInput 每帧更新）
- [x] 布局系统（Flexbox: row/column/wrap, justify/align, padding/margin）
- [x] 常用控件（Panel, Label, Button, ProgressBar 通过 Canvas 便捷 API）
- [x] render pass 集成（ui_overlay pass，tonemap 后合成）
- [x] 脚本 API 暴露（Zig host functions + C# SDK）
- [x] Debug HUD（FPS/DrawCalls/Entities 叠加层）
- [ ] 9-patch/sprite 图片渲染（待实现）
- [ ] ScrollView 控件（待实现）
- [ ] 拖拽交互（待实现）

---

### 2. AI 行为系统 🟡 中优先级

**当前状态**: 零（仅有 NavAgent 寻路）。插件类型定义了 `ai_behavior` 但无实现。

**RTS/4X 关键需求**: 敌军 AI 决策、单位自动行为、城市 AI。

**需要实现**:
- [ ] 行为树（Behavior Tree）运行时
  - Sequence, Selector, Parallel 节点
  - Decorator（条件/重复/反转）
  - Action/Condition 叶节点
- [ ] 黑板（Blackboard）数据共享
- [ ] 有限状态机（FSM）组件
- [ ] 脚本 API（Zig/C# 自定义节点）
- [ ] 可选：效用 AI（Utility AI）评分系统

**可选方案**:
- A) 纯脚本层实现（最快原型）
- B) ECS-native 行为树组件（性能好，可序列化）
- C) 可视化编辑器集成（长期）

**预估工作量**: 中（1-2 周核心运行时，不含编辑器）

---

### 3. 网络/多人系统 🔴 高难度

**当前状态**: 零。WebSocket RPC 仅用于编辑器通信，无游戏级网络。

**FPS/RTS 需要**: 实时同步。4X 可用 turn-based 降低需求。

**需要实现**:
- [ ] 传输层（UDP/WebSocket/QUIC）
- [ ] 序列化协议（帧数据/状态快照）
- [ ] 客户端预测 + 服务端权威
- [ ] 延迟补偿 / 插值
- [ ] 大厅/房间系统
- [ ] 断线重连
- [ ] 可选 dedicated server 模式

**可选方案**:
- A) Lockstep（RTS 经典，确定性物理）
- B) 快照插值（FPS 经典，Valve-style）
- C) ECS 状态同步（通用）

**预估工作量**: 极大（4-8 周核心功能，不含反作弊/匹配）

---

### 4. 地形系统 🔴 高优先级（RTS/4X）

**当前状态**: 零。插件类型定义了 `terrain_gen` 但无实现。

**需要实现**:
- [ ] Heightmap 地形网格生成
- [ ] LOD（Clipmap 或 CDLOD）
- [ ] 多层纹理混合（Splatmap）
- [ ] Sculpt/Paint 编辑工具（编辑器）
- [ ] 与 NavMesh 集成
- [ ] 与物理碰撞集成（heightfield collider）
- [ ] 可选：程序化地形生成（噪声 + 侵蚀）

**预估工作量**: 大（2-4 周渲染+碰撞，编辑器另算）

---

### 5. 战争迷雾（Fog of War）🟡 中优先级（RTS/4X）

**当前状态**: 零。

**需要实现**:
- [ ] 可见性数据结构（per-tile 或 per-pixel）
- [ ] 视野计算（圆形/扇形/射线遮挡）
- [ ] GPU compute pass 渲染（explored / visible / hidden）
- [ ] 与 minimap 联动
- [ ] 动态更新（单位移动时实时刷新）
- [ ] 脚本 API（查询某坐标是否可见）

**预估工作量**: 中（1-2 周基础实现）

---

### 6. FPS 相机控制器 🟢 低难度

**当前状态**: 有 Camera 组件和 Transform，但无预置 FPS 控制器。

**需要实现**:
- [ ] 鼠标看向（Yaw + Pitch 限制）
- [ ] WASD 移动（与 CharacterController 集成）
- [ ] 头部摆动（Head bob）
- [ ] 冲刺 / 蹲下 / 跳跃
- [ ] 可选：ADS（瞄准）FOV 过渡

**预估工作量**: 小（2-3 天，可纯脚本实现）

---

### 7. RTS 相机控制器 🟢 低难度

**需要实现**:
- [ ] WASD / 边缘滚动移动
- [ ] 滚轮缩放（正交 ↔ 透视混合）
- [ ] 中键拖拽旋转
- [ ] 地形高度跟随
- [ ] 小地图点击跳转

**预估工作量**: 小（2-3 天，可纯脚本实现）

---

### 8. 单位选择系统 🟢 低难度（RTS）

**当前状态**: 已有 `viewport.boxSelect` RPC 和空间 BVH 查询。

**需要实现**:
- [ ] 框选 UI 矩形绘制
- [ ] 框选 → 空间查询 → 选中单位列表
- [ ] Shift/Ctrl 多选
- [ ] 双击选同类型
- [ ] 编组（Ctrl+1~9）
- [ ] 右键指令（移动/攻击/巡逻）

**预估工作量**: 小（3-5 天，大部分脚本层）

---

### 9. 资源/经济系统 🟡 中优先级（RTS/4X）

**需要实现**:
- [ ] 资源类型定义（金/木/食物/科技点）
- [ ] 采集逻辑（采集速度、运输时间）
- [ ] 建筑生产队列
- [ ] 人口/供给限制
- [ ] 交易/外交
- [ ] UI 显示

**预估工作量**: 中（纯逻辑层，可脚本实现，2-3 周）

---

### 10. 回合制框架 🟡 中优先级（4X/文明）

**需要实现**:
- [ ] 回合管理器（Turn Manager）
- [ ] 玩家轮次调度
- [ ] AI 回合处理
- [ ] 动作队列 / 动画播放等待
- [ ] 存档时回合状态序列化

**预估工作量**: 中（1-2 周核心框架）

---

## 推荐实施路线

```
Phase 1 — FPS 原型（最少引擎改动）
├── FPS 相机控制器    [脚本] 2-3天
├── 武器系统原型      [脚本] 3-5天
├── 最小 HUD overlay  [引擎] 3-5天（数字+准星）
└── 验证: Physics/Animation/Audio 端到端

Phase 2 — 补通用引擎能力
├── 运行时 UI 系统    [引擎] 2-4周
├── AI 行为树         [引擎] 1-2周
└── 验证: 用 Zig 脚本创建完整 FPS 关卡

Phase 3 — RTS 原型
├── RTS 相机控制器    [脚本] 2-3天
├── 单位选择系统      [脚本+引擎] 3-5天
├── 战争迷雾          [引擎] 1-2周
├── 资源/经济框架     [脚本] 2周
└── 验证: 小规模 RTS 对战

Phase 4 — 4X 基础
├── 地形系统          [引擎] 2-4周
├── 回合制框架        [脚本+引擎] 1-2周
├── 地图生成          [引擎] 2-3周
└── 验证: 文明 MVP
```

## 每个缺失系统对三种类型的需求矩阵

| 缺失系统          | FPS | RTS | 4X/文明 | 总优先分 |
|-------------------|-----|-----|---------|----------|
| ~~运行时 UI~~    | ~~★★★★~~ | ~~★★★★★~~ | ~~★★★★★~~ | **✅ 已完成** |
| AI 行为系统      | ★★★ | ★★★★★ | ★★★★★ | **13** |
| 地形系统         | ★★★★ | ★★★★ | ★★★★★ | **13** |
| 网络/多人        | ★★★★★ | ★★★★ | ★★★ | **12** |
| 战争迷雾         | ✗ | ★★★★★ | ★★★★ | **9** |
| 资源/经济系统    | ✗ | ★★★★ | ★★★★★ | **9** |
| FPS 相机控制器   | ★★★★★ | ✗ | ✗ | **5** |
| RTS 相机控制器   | ✗ | ★★★★★ | ★★★★★ | **10** |
| 单位选择系统     | ✗ | ★★★★★ | ★★★ | **8** |
| 回合制框架       | ✗ | ✗ | ★★★★★ | **5** |
