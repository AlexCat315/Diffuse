# P9 物理系统 MVP 设计说明

## 目标

先落成一版可运行的物理闭环，并把第三方后端隔离在物理模块内部，补齐以下链路：

- 运行时存在基础物理组件
- `Application` 有固定步长物理更新
- 场景树与物理结果可双向同步
- 场景序列化能保存与恢复物理组件
- 后续能平滑演进 Jolt backend，而不是把第三方 API 直接扩散进核心模块

## 当前实现边界

当前 `src/engine/physics/system.zig` 已经是双 backend 结构：

- 默认 `backend = .jolt`
- 保留 `backend = .builtin` 作为 fallback / debug 路径

当前能力边界如下：

- `Rigidbody`
- `BoxCollider`
- `SphereCollider`
- `MeshCollider`
- Jolt 刚体步进与结果回写
- builtin solver 下的 dynamic 刚体积分
- builtin solver 下的 dynamic 对 static / kinematic / 纯 collider 目标的基础 AABB 接触解算
- 固定步长调度与场景同步

当前明确**不覆盖**：

- trigger 事件回调
- 约束、关节、连续碰撞检测
- layer / mask 过滤
- collider / rigidbody debug draw
- 持久化 Jolt world / body 缓存

当前已知限制：

- Jolt backend 初版采用桥接型实现，每次 `step` 会从 `World` 重建一次 Jolt world，再把结果回写。
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
- `SphereCollider`
- `MeshCollider`

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

## 场景兼容性

场景序列化版本已升到 `v5`。

新增可保存字段：

- `rigidbody`
- `box_collider`
- `sphere_collider`
- `mesh_collider`

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

1. 把当前桥接型 Jolt step 收敛成持久化 world / body 缓存
2. 增加 trigger 与 layer/filter
3. 做 collider / rigidbody debug draw
4. 增加约束与更完整查询接口
