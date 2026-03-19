# P9 物理系统 MVP 设计说明

## 目标

先落成一版不依赖第三方物理库的最小可运行链路，补齐以下闭环：

- 运行时存在基础物理组件
- `Application` 有固定步长物理更新
- 场景树与物理结果可双向同步
- 场景序列化能保存与恢复物理组件
- 后续能平滑切到 Jolt，而不是把第三方 API 直接扩散进核心模块

## 当前实现边界

当前 `src/engine/physics/system.zig` 是内建 bounds-based solver，只覆盖 MVP 范围：

- `Rigidbody`
- `BoxCollider`
- `SphereCollider`
- `MeshCollider`
- dynamic 刚体积分
- dynamic 对 static / kinematic / 纯 collider 目标的基础 AABB 接触解算

当前明确**不覆盖**：

- dynamic-dynamic 碰撞
- trigger 事件回调
- 约束、关节、连续碰撞检测
- layer / mask 过滤
- 第三方后端接入

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

这样后续替换成 Jolt，只需要把 `physics/system.zig` 的 step 内核替换掉，不需要改 `Application` 调度层。

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

1. 接入 Jolt 适配层
2. 增加 trigger 与 layer/filter
3. 做 collider / rigidbody debug draw
4. 增加 dynamic-dynamic、约束与更完整查询接口
