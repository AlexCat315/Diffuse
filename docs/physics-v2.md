---
path: /zh/docs/physics-v2
title: Physics v2
description: Guava 的 Jolt 物理运行阶段、车辆 API、状态资源与当前能力边界。
locale: zh
translationKey: docs.physics-v2
category: 核心概念
order: 45
kind: doc
---

# Physics v2

Guava Physics v2 使用 Jolt 作为唯一生产物理后端。当前已完成复合碰撞体、统一查询与事件、原生角色控制器、类型化关节、布娃娃、增量同步、确定性命令回放，以及 M5 的首个轮式载具闭环。

## 帧阶段

每帧按以下顺序执行：

1. 输入和脚本 `onPrePhysics` 提交角色、载具与刚体命令。
2. ECS 的增量变化同步到 Jolt。
3. 按固定时间步模拟。
4. 活动且发生变化的刚体写回 ECS；角色和载具写入专用帧资源。
5. 脚本 `onUpdate` 读取本帧结果。

因此，在 `onPrePhysics` 提交的油门、转向、跳跃、力和冲量会被当前物理帧消费。

## 轮式载具

`Vehicle` 必须与同一实体上的动态 `RigidBody` 和 `Collider` 配合使用。默认构造器生成四轮布局：前轮转向，后轮驱动并支持手刹。

```swift
let car = scene.createEntity()
_ = scene.setLocalTransform(
    LocalTransform(translation: SIMD3<Float>(0, 1.2, 0)),
    for: car
)
_ = scene.setComponent(
    Collider(shape: .box(
        halfExtents: SIMD3<Float>(1, 0.35, 1.8),
        center: .zero
    )),
    for: car
)
_ = scene.setComponent(
    RigidBody(motionType: .dynamic, mass: 1_200),
    for: car
)
_ = scene.setComponent(Vehicle(), for: car)

scene.submitVehicleCommand(
    VehicleCommand(throttle: 1, steering: 0.25),
    for: car
)
_ = scene.tick(deltaTime: 1.0 / 60.0)

let state = scene.vehicleStateFrame.states[car]
```

`Vehicle` 可配置任意轮数的车轮、悬挂、转向、制动、手刹、发动机、自动或手动变速箱、差速器和防倾杆。`VehicleStateFrameResource` 提供车速、发动机转速、当前档位、离合器摩擦以及逐轮世界变换、悬挂长度和接触信息。

## 稳定性和序列化

- 车辆创建、删除、命令和状态按 `EntityID` 稳定排序。
- 发动机、档位、离合器和逐轮状态参与物理检查点哈希。
- 车辆配置支持 Scene v2 与 Editor Manifest v5 往返。
- C ABI 通过独立车辆布局表校验所有结构尺寸，并对无效车轮或索引返回明确错误。
- AI 场景语义包含车辆配置和最新运行状态摘要。

## 当前边界

M5 尚未完成。当前交付的是基于 Jolt `VehicleConstraint` 的轮式载具基础链路；履带和双轮控制器、斜坡/跳台/摩擦材质/碰撞恢复/移动平台验收场景，以及完整的逐轮 Editor 数组工具仍在后续迭代中。
