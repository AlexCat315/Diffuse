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
| AI 行为树 | `src/engine/behavior/` | Sequence/Selector/Parallel，Decorator 装饰器，Action/Condition/Wait 叶节点，per-entity Blackboard，Builder API |
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

### 2. AI 行为系统 ✅ 已完成

**当前状态**: 已实现。ECS-native 行为树运行时 + per-entity Blackboard + C# SDK。

**实现文件**:
- `src/engine/behavior/behavior_tree.zig` — 核心 BT：Status/NodeKind/BtNode/BehaviorTree/Builder/Blackboard
- `src/engine/behavior/bt_system.zig` — ECS 系统：BehaviorTreeComponent + update() 迭代器
- `sdk/csharp/GuavaEngine/GuavaBehaviorTree.cs` — C# 行为树 SDK（纯 C# 实现）

**已完成项**:
- [x] 行为树运行时（Sequence/Selector/Parallel 组合节点）
- [x] Decorator（Inverter/Repeater/Succeeder/RepeatUntilFail/Cooldown）
- [x] Action/Condition/Wait 叶节点（用户回调）
- [x] per-entity Blackboard（typed key-value: int/float/bool/string）
- [x] Builder API（链式构建）
- [x] ECS 组件集成（BehaviorTreeComponent 自动每帧 tick）
- [x] 主循环集成（nav_system → bt_system → scripts 顺序）
- [x] C# SDK（Sequence/Selector/Parallel/Inverter/Succeeder/Cooldown/Action/Condition/Wait）
- [ ] 有限状态机（FSM）组件（待实现）
- [ ] 效用 AI（Utility AI）评分系统（待实现）
- [ ] 可视化编辑器集成（待实现）

---

### 3. 网络/多人系统 ✅ 基础实现完成

**当前状态**: 纯 Zig 实现的 UDP 网络协议栈，无 C 依赖。

**已实现**:
- [x] 传输层 — 非阻塞 UDP 套接字 (`network/transport.zig`)
- [x] 可靠传输 — 序列号 + ACK 位域 + 200ms 重传
- [x] 包协议 — 13 字节头 + 手动序列化/反序列化 (`network/protocol.zig`)
- [x] 多通道 — reliable / unreliable / unreliable_sequenced / control
- [x] 会话管理 — Host/Client 模式、4 步握手、心跳、超时检测 (`network/session.zig`)
- [x] 实体同步 — NetworkIdentity + NetworkTransform ECS 组件 (`network/net_system.zig`)
- [x] 状态复制 — Host 广播 TransformSnapshot，Client 插值
- [x] 已集成主循环 — `application.zig` 每帧调用 `net_system.update()`
- [x] 最多 16 玩家、RTT 估算
- [x] C# SDK API (`GuavaNetwork.cs` — NetworkManager + RPC 编解码)

**待完善**:
- [ ] 客户端预测 + 服务端权威
- [ ] 大厅/房间/匹配系统
- [ ] 断线重连
- [ ] 帧同步 (Lockstep) 模式
- [ ] 反作弊
- [ ] HostApi 扩展（C# 脚本直接调用原生网络 API）

---

### 4. 地形系统 ✅ 基础实现完成

**当前状态**: 基础地形系统已实现。

**已实现**:
- [x] Heightmap 地形网格生成 (`src/engine/terrain/terrain.zig`)
- [x] TerrainComponent ECS 组件 + Entity/EntityDesc 字段
- [x] GPU 渲染管线 (terrain.vert/frag GLSL → TerrainRenderer)
- [x] 集成到 Renderer.drawFrame() base_pass 阶段
- [x] 高度查询 (bilinear interpolation)
- [x] 程序化地形生成 (multi-octave sin/cos hills)
- [x] LOD 数据结构 (TerrainChunk with 4 LOD levels)

**待完善**:
- [ ] LOD 实际切换（Clipmap 或 CDLOD）
- [ ] 多层纹理混合（Splatmap）
- [ ] Sculpt/Paint 编辑工具（编辑器）
- [ ] 与 NavMesh 集成
- [ ] 与物理碰撞集成（heightfield collider）

**实现文件**:
- `src/engine/terrain/terrain.zig` — Heightmap, TerrainMesh, generateMesh, Terrain
- `src/engine/terrain/terrain_renderer.zig` — TerrainRenderer (pipeline, buffers, draw, syncAndDraw)
- `assets/shaders/terrain.vert.glsl` / `terrain.frag.glsl` — 地形着色器
- `src/engine/scene/components.zig` — TerrainComponent

---

### 5. 战争迷雾（Fog of War）✅ 已完成

**实现状态**:
- [x] 可见性数据结构（per-tile VisibilityGrid，unexplored/explored/visible 三态）
- [x] 视野计算（圆形区域，按实体 FogVision.sight_range 揭露）
- [x] GPU fullscreen overlay 渲染（CPU 计算 → R8 纹理上传 → fragment shader 混合）
- [x] 动态更新（每帧清除当前可见，重新计算，与 explored 合成）
- [x] 团队支持（team_id 过滤，仅渲染本地队伍视野）
- [x] ECS 集成（FogVision / FogOfWarConfig 组件，FogOfWarSystem）
- [ ] 与 minimap 联动（待 minimap 系统实现后集成）
- [ ] 脚本 API（查询某坐标是否可见）

**关键文件**:
- `src/engine/fog/fog_system.zig` — CPU 可见性网格 + ECS 系统
- `src/engine/render/passes/fog_of_war_pass.zig` — GPU fullscreen overlay pass
- `assets/shaders/fog_of_war.frag.glsl` — 迷雾 fragment shader

---

### 6. FPS 相机控制器 ✅ 已完成

**实现状态**:
- [x] 鼠标视角（Yaw + Pitch，可配置灵敏度、反转 Y、±85° 限制）
- [x] WASD 移动（加速/摩擦物理模型，非瞬移）
- [x] 头部摆动（Head Bob，频率/幅度可配置，冲刺时加速）
- [x] 冲刺（Shift）/ 蹲下（Ctrl toggle）
- [x] ADS 瞄准 FOV 过渡（右键按住，平滑插值，灵敏度降低）
- [x] 蹲下高度过渡（eye_height / crouch_eye_height）
- [x] ECS 集成（FpsCamera + FpsCameraConfig 组件）

**关键文件**:
- `src/engine/camera/fps_camera.zig` — FPS 相机控制器

---

### 7. RTS 相机控制器 ✅ 已完成

**实现状态**:
- [x] WASD / 方向键 / 屏幕边缘滚动平移
- [x] 滚轮缩放（透视/正交）
- [x] 中键拖拽平移
- [x] Alt+RMB / Q/E 旋转
- [x] 地图边界约束
- [x] 可配置参数（速度、灵敏度、边距、缩放范围、俯仰范围）
- [x] ECS 组件化（RtsCamera 组件）
- [x] 集成到引擎主循环

**实现文件**: `src/engine/camera/rts_camera.zig`

---

### 8. 单位选择系统 ✅ 已完成

**实现状态**:
- [x] 框选（拖拽矩形，屏幕空间投影匹配）
- [x] 点击选择（最近实体，30px 容差）
- [x] Shift 多选 / 取消选中
- [x] 双击选同类型（基于 unit_type_id，仅屏幕内可见）
- [x] 编组（Ctrl+1~3 保存，1~3 召回，每组最多 64 单位）
- [x] 右键指令系统（CommandReceiver 组件，CommandKind: move/attack/patrol/stop/hold）
- [x] 队伍过滤（仅选择 local_team_id 对应的单位）
- [x] ECS 集成（UnitSelectable + CommandReceiver 组件）
- [ ] 框选 UI 矩形绘制（待 UI 系统集成后实现）

**关键文件**:
- `src/engine/selection/selection_system.zig` — 选择系统 + 组件定义

---

### 9. 资源/经济系统 ✅ 已完成

**实现状态**:
- [x] 资源类型定义（gold/wood/food/stone/tech/supply + 2 custom 槽位，最多 8 种）
- [x] ResourceStorage 组件（附着在玩家实体上，含容量上限、安全加减、canAfford 查询）
- [x] 采集逻辑（ResourceHarvester + ResourceNode 组件，自动采集→背包→卸货循环）
- [x] 建筑生产队列（ProductionQueue 组件，最多 8 条排队，自动推进计时）
- [x] 人口/供给限制（SupplyProvider + SupplyConsumer 组件，每帧自动计算上限和占用）
- [x] 交易系统（TradeOffer 组件 + executeTrade 辅助函数）
- [x] ECS 集成（7 个组件注册到 Entity/EntityDesc，EconomySystem 每帧 tick）
- [ ] UI 显示（待 UI 系统集成后实现）

**关键文件**:
- `src/engine/economy/economy_system.zig` — 全部组件定义 + EconomySystem + 采集/生产/供给子系统

---

### 10. 回合制框架 ✅ 已完成

**实现状态**:
- [x] 回合管理器（TurnSystem — 状态机：waiting → player_action → animation → ai_processing → end_of_turn）
- [x] 玩家轮次调度（多玩家循环，自动切换人类/AI 玩家）
- [x] AI 回合处理（ai_processing 阶段，由外部 AI 系统调用 endAiTurn 完成）
- [x] 动作队列 / 动画播放等待（ActionQueueEntry，FIFO 顺序播放，完成后自动推进）
- [x] 行动点系统（TurnPlayer.action_points / max_action_points，每回合重置）
- [x] TurnActor 组件（per-unit 行动次数追踪）
- [x] ECS 集成（TurnConfig + TurnPlayer + TurnActor 组件）
- [ ] 存档时回合状态序列化（待存档系统实现后集成）

**关键文件**:
- `src/engine/turnbased/turn_system.zig` — 回合系统 + 组件定义

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
├── 地形系统          [引擎] ✅ 基础完成
├── 回合制框架        [脚本+引擎] 1-2周
├── 地图生成          [引擎] 2-3周
└── 验证: 文明 MVP
```

## 每个缺失系统对三种类型的需求矩阵

| 缺失系统          | FPS | RTS | 4X/文明 | 总优先分 |
|-------------------|-----|-----|---------|----------|
| ~~运行时 UI~~    | ~~★★★★~~ | ~~★★★★★~~ | ~~★★★★★~~ | **✅ 已完成** |
| ~~AI 行为系统~~  | ~~★★★~~ | ~~★★★★★~~ | ~~★★★★★~~ | **✅ 已完成** |
| ~~地形系统~~     | ~~★★★★~~ | ~~★★★★~~ | ~~★★★★★~~ | **✅ 基础完成** |
| ~~网络/多人~~    | ~~★★★★★~~ | ~~★★★★~~ | ~~★★★~~ | **✅ 基础完成** |
| 战争迷雾         | ~~✗~~ | ~~★★★★★~~ | ~~★★★★~~ | **✅ 已完成** |
| 资源/经济系统    | ~~✗~~ | ~~★★★★~~ | ~~★★★★★~~ | **✅ 已完成** |
| FPS 相机控制器   | ~~★★★★★~~ | ~~✗~~ | ~~✗~~ | **✅ 已完成** |
| RTS 相机控制器   | ~~✗~~ | ~~★★★★★~~ | ~~★★★★★~~ | **✅ 已完成** |
| 单位选择系统     | ~~✗~~ | ~~★★★★★~~ | ~~★★★~~ | **✅ 已完成** |
| 回合制框架       | ~~✗~~ | ~~✗~~ | ~~★★★★★~~ | **✅ 已完成** |
