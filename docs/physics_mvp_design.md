# P9 物理系统 MVP 设计说明

## 目标

先落成一版可运行的物理闭环，并把第三方后端隔离在物理模块内部，补齐以下链路：

- 运行时存在基础物理组件
- `Application` 有固定步长物理更新
- 场景树与物理结果可双向同步
- 场景序列化能保存与恢复物理组件
- 后续能平滑演进 Jolt backend，而不是把第三方 API 直接扩散进核心模块

## 当前实现边界 (P9 完成)

当前 `src/engine/physics/system.zig` 已经是双 backend 结构：

- 默认 `backend = .jolt`
- 保留 `backend = .builtin` 作为 fallback / debug 路径

### P9 完成的核心优化

1. **持久化 Body 缓存** ✅
   - 将桥接型 Jolt step 收敛为持久化 world/body 缓存
   - 事件驱动的增量更新机制
   - 避免每帧重建 Body 的开销

2. **Trigger 事件系统** ✅
   - 实现 OnContact 回调机制
   - 支持 TriggerEnter/Stay/Exit 事件
   - 线程安全的事件队列

3. **Layer 系统扩展** ✅
   - Collider 组件新增 `layer_id` 和 `layer_group` 字段
   - 支持自定义 Layer 和碰撞矩阵
   - 为后续完整 Layer 过滤做准备

当前能力边界如下：

- `Rigidbody` (static/dynamic/kinematic)
- `BoxCollider` (支持 trigger 和 layer)
- `SphereCollider` (支持 trigger 和 layer)
- `MeshCollider` (支持 trigger 和 layer)
- Jolt 刚体步进与结果回写
- builtin solver 下的 dynamic 刚体积分
- builtin solver 下的 dynamic 对 static / kinematic / 纯 collider 目标的基础 AABB 接触解算
- 固定步长调度与场景同步
- Trigger 事件回调
- Layer 基础架构
- 持久化 Jolt world / body 缓存

当前明确**不覆盖**：

- 约束、关节、连续碰撞检测
- collider / rigidbody debug draw
- 完整 Layer 过滤（C++ 层实现）

当前已知限制：

- `MeshCollider` 在 Jolt 路径里暂时以 bounds proxy box 进入后端，不是完整 triangle mesh shape。
- 因为保留了 builtin fallback，Jolt 初始化失败时仍能回退到最小可运行路径。

## 数据结构

物理组件定义在 `src/engine/scene/components.zig`：

- `Rigidbody`
  - `motion_type`
  - `mass`
  - `linear_velocity`
  - `gravity_scale`
  - `linear_damping`
  - `allow_sleep`
- `BoxCollider`
  - `layer_id` / `layer_group` (P9 新增)
- `SphereCollider`
  - `layer_id` / `layer_group` (P9 新增)
- `MeshCollider`
  - `layer_id` / `layer_group` (P9 新增)

这些字段直接挂在 `World.Entity` 上，并跟随 `EntityDesc`、复制、统计、bootstrap 一起流转。

## 主循环接入

`Application` 新增：

- `ApplicationConfig.physics`
- `physics_accumulator_seconds`
- `advancePhysics(delta_seconds)`

运行顺序为：

1. 常规帧 `delta_seconds`
2. animator 更新
3. 物理累积器按 `fixed_timestep_seconds` 消化多个 substep
4. 每个 substep 内：
   - 更新层级缓存
   - 积分 dynamic 刚体
   - 解 static / kinematic 接触
   - 回写场景变换

这样后续继续优化 Jolt backend，只需要收敛 `physics/system.zig` 内部状态管理，不需要改 `Application` 调度层。

## 事件驱动架构 (P9 新增)

物理系统现在采用事件驱动的增量更新机制：

- `PhysicsEvent` 枚举：entity_created/destroyed, rigidbody/collider 添加/移除, transform 变更
- `enqueuePhysicsEvent()`：实体变更时入队
- `processPhysicsEvents()`：每帧处理事件队列，增量更新 Jolt World
- `TriggerEvent` 结构：entity_a, entity_b, kind (enter/stay/exit)
- `setTriggerCallback()`：用户可注册触发器回调

## 场景兼容性

场景序列化版本已升到 `v5`。

新增可保存字段：

- `rigidbody`
- `box_collider` (含 layer 信息)
- `sphere_collider` (含 layer 信息)
- `mesh_collider` (含 layer 信息)

旧版本兼容策略：

- `v3 / v4` 仍可读
- `v5` 开始写入物理组件

## 调试与日志

当前已接入低频物理日志：

- 首次打印物理配置
- dynamic/static/contact 计数变化时打印摘要

目的不是做 profiler，而是先把“物理到底有没有在跑”这个问题变成可观测状态。

## 后续演进

下一步按优先级建议：

1. ✅ 把当前桥接型 Jolt step 收敛成持久化 world / body 缓存 (P9 完成)
2. ✅ 增加 trigger 与 layer/filter 基础架构 (P9 完成)
3. 做 collider / rigidbody debug draw
4. 增加约束与更完整查询接口
5. 完成 C++ 层 Layer 过滤实现
