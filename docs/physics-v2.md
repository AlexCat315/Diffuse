---
path: /zh/docs/physics-v2
title: Physics v2
description: Guava 的 Jolt 物理运行阶段、载具、布料状态资源与当前能力边界。
locale: zh
translationKey: docs.physics-v2
category: 核心概念
order: 45
kind: doc
---

# Physics v2

Guava Physics v2 使用 Jolt 作为唯一生产物理后端。当前已完成复合碰撞体、统一查询与事件、原生角色控制器、类型化关节、布娃娃、增量同步、确定性命令回放、M5 的三类载具控制器，以及 M6 的首个原生布料切片。

## 帧阶段

每帧按以下顺序执行：

1. 输入和脚本 `onPrePhysics` 提交角色、载具与刚体命令。
2. ECS 的增量变化同步到 Jolt。
3. 按固定时间步模拟。
4. 活动且发生变化的刚体写回 ECS；角色、载具和软体顶点写入各自的专用帧资源。
5. 脚本 `onUpdate` 读取本帧结果。

因此，在 `onPrePhysics` 提交的油门、转向、跳跃、力和冲量会被当前物理帧消费。

## 载具

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

三种控制器共享 `VehicleCommand` 和 `VehicleStateFrameResource`：

```swift
let car = Vehicle()
let tank = Vehicle.tracked()
let bike = Vehicle.motorcycle()
```

履带控制器把 `steering` 映射为左右履带速度比；静止时的转向命令会执行原地转向。摩托车控制器提供最大倾角、平衡弹簧、阻尼、积分衰减、平滑和倾斜转向限制配置。

## 布料与软体状态流

首个 M6 切片由同一实体上的 `SoftBody` 和 `Cloth` 组成。`Cloth` 定义规则网格、间距、固定顶点、拉伸/剪切/弯曲柔度和弯曲约束类型；`SoftBody` 定义质量、压力、阻尼、摩擦、反弹、重力倍率、顶点半径、求解迭代和碰撞层。

```swift
let banner = scene.createEntity()
_ = scene.setLocalTransform(
    LocalTransform(translation: SIMD3<Float>(0, 4, 0)),
    for: banner
)
_ = scene.setComponent(
    Cloth.fixedTopEdge(gridSizeX: 16, gridSizeZ: 16, spacing: 0.15),
    for: banner
)
_ = scene.setComponent(SoftBody(allowSleep: false), for: banner)

_ = scene.tick(deltaTime: 1.0 / 60.0)
let deformedMesh = scene.softBodyStateFrame.states[banner]
```

变形后的世界空间顶点和三角形索引写入 `SoftBodyStateFrameResource`，不会逐顶点写回普通 ECS `Transform`。带有可见 `RenderMeshComponent` 的布料还会提取为 `RenderDeformableMesh`：渲染后端按实体维护动态 GPU 顶点/索引缓冲区，内容 revision 未变化时不重复上传，拓扑未变化时只更新顶点。深度、阴影、基础、描边和 Render Bundle 路径都使用同一份变形网格，阴影范围也按当前世界空间顶点计算。创建、增量重建、删除、状态复制和渲染提取按 `EntityID` 稳定排序。

`RenderFrameStats` 分别记录变形网格数、顶点数、三角形数、拒绝的无效网格、上传字节和上传耗时；Editor 的 Render 调试面板直接显示这些指标。没有固定物理子步的渲染帧会继续复用最近一次软体状态和 GPU 缓冲区，不会让布料闪退一帧。当前 Jolt 版本没有暴露软体自碰撞设置，因此 `selfCollision: true` 会返回明确的 `invalidArgument`，不会静默降低能力。

## 稳定性和序列化

- 车辆创建、删除、命令和状态按 `EntityID` 稳定排序。
- 发动机、档位、离合器和逐轮状态参与物理检查点哈希。
- 车辆配置支持 Scene v2 与 Editor Manifest v5 往返。
- C ABI v4 校验刚体、角色、载具和软体结构尺寸，并对无效配置返回明确错误。
- AI 场景语义包含载具、软体和布料的配置，以及可用的最新运行状态摘要。
- `cloth-64` 和 `soft-body-instances` 基准分别对 64×64 单布料、8 个 32×32 实例统计 step 与顶点流 p50/p95/p99、内存和丢弃子步，并使用独立预算门禁。

## 当前边界

M5 已完成。M6 当前具备 Jolt 原生规则网格布料、固定点、压力/阻尼等参数、增量同步、Scene v2 与 Manifest v5 往返、专用变形顶点流、按 revision 缓存的真实 GPU 网格上传、所有网格渲染通道与阴影范围集成、静态/动态刚体/角色碰撞验收、Editor 参数/固定点编辑与上传性能统计，以及 64×64 和多实例性能门禁。任意网格/体积软体资产、自碰撞和 Editor 约束可视化仍在后续切片中。
