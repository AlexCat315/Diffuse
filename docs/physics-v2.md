---
path: /zh/docs/physics-v2
title: Physics v2
description: Guava 的 Jolt 物理运行阶段、载具、软体与预破碎破坏系统，以及当前能力边界。
locale: zh
translationKey: docs.physics-v2
category: 核心概念
order: 45
kind: doc
---

# Physics v2

Guava Physics v2 使用 Jolt 作为唯一生产物理后端。当前已完成复合碰撞体、统一查询与事件、原生角色控制器、类型化关节、布娃娃、增量同步、确定性命令回放、M5 的三类载具控制器、M6 的规则布料与任意三角表面软体，以及 M7 的预破碎破坏系统。

## 帧阶段

每帧按以下顺序执行：

1. 输入和脚本 `onPrePhysics` 提交角色、载具、刚体与破坏命令。
2. ECS 的增量变化同步到 Jolt。
3. 按固定时间步模拟。
4. 活动且发生变化的刚体写回 ECS；角色、载具和软体顶点写入各自的专用帧资源。
5. 脚本 `onUpdate` 读取本帧结果。

因此，在 `onPrePhysics` 提交的油门、转向、跳跃、力和冲量会被当前物理帧消费。

## Editor 物理创作与调试

Collider Inspector 同时提供首个形状的快捷参数和结构化 Compound 子形状卡片；可以新增、删除和稳定排序子形状，并为每个 `ColliderShapeInstance` 独立设置形状、局部位置、四元数旋转和缩放，修改后直接写回 `Collider.shapes`。完整 JSON 保留为高级编辑入口。Capsule、Cylinder 与 HeightField 使用各自独立字段，HeightField 不再错误显示 Capsule 的半高。

`PhysicsJoint` Inspector 可从带 Collider 的实体中选择两个不同端点，并按 Point、Fixed、Distance、Hinge、Slider、Cone/SwingTwist 与 SixDOF 类型显示配置，分别编辑锚点、轴、线性/角度限位、电机、弹簧、阻尼和断裂阈值。Viewport 直接消费统一 `PhysicsDebugFrameResource`，为当前选择绘制 Compound 子形状、AABB、接触点与法线、休眠/Trigger 状态、关节锚点/轴/限位，以及角色地面法线；工具栏可以独立开关碰撞形状、边界、接触、关节和角色地面类别，设置随 Editor 状态持久化，视口图例显示当前启用类别。结果按运行时稳定顺序输出并设置显示容量上限。

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

软体实体由 `SoftBody` 与一种拓扑组件组成。`Cloth` 定义规则网格、间距、固定顶点、拉伸/剪切/弯曲柔度和弯曲约束类型；`SoftBodyMesh` 引用 `MeshColliderGeometryResource` 中的任意三角表面资产，并为它定义固定顶点与约束柔度。资源可额外提供每组四个索引的 `tetrahedronIndices`；此时后端会补齐四面体内部边并创建 Jolt 体积约束，`volumeCompliance` 控制其柔度。两种拓扑不能同时添加。`SoftBody` 统一定义质量、压力、阻尼、摩擦、反弹、重力倍率、顶点半径、求解迭代和碰撞层；启用 `selfCollision` 后，`vertexRadius` 同时作为同实体顶点—三角面接触厚度且必须大于零。

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

导入网格可以直接复用按资源 ID 和 revision 缓存的顶点、三角形及 UV 数据：

```swift
let softProp = scene.createEntity()
scene.setResource(MeshColliderGeometryResource(geometryByResourceID: [
    "asset:soft-tetra": MeshColliderGeometry(
        positions: tetraVertices,
        triangleIndices: surfaceTriangles,
        tetrahedronIndices: volumeTetrahedra,
        revision: 1
    )
]))
_ = scene.setComponent(
    SoftBodyMesh(
        resourceID: "asset:soft-tetra",
        fixedVertexIndices: [0, 3],
        volumeCompliance: 1.0e-6,
        bendType: .distance
    ),
    for: softProp
)
_ = scene.setComponent(SoftBody(allowSleep: false), for: softProp)
```

`SoftBodyMesh.resourceID` 未解析、拓扑索引越界、退化三角形、零体积/重复顶点四面体或同时存在 `Cloth` 与 `SoftBodyMesh` 时，当前物理帧返回明确的 `invalidArgument`，不会创建替代形状。四面体索引必须由导入流程预先生成；运行时不会对普通表面网格自动四面体化。

变形后的世界空间顶点和三角形索引写入 `SoftBodyStateFrameResource`，不会逐顶点写回普通 ECS `Transform`。带有可见 `RenderMeshComponent` 的布料还会提取为 `RenderDeformableMesh`：渲染后端按实体维护动态 GPU 顶点/索引缓冲区，内容 revision 未变化时不重复上传，拓扑未变化时只更新顶点。深度、阴影、基础、描边和 Render Bundle 路径都使用同一份变形网格，阴影范围也按当前世界空间顶点计算。创建、增量重建、删除、状态复制和渲染提取按 `EntityID` 稳定排序。

Jolt 5.5 没有暴露同一软体内部的自碰撞求解开关，因此 Guava 桥接层在固定步后使用空间哈希生成非相邻顶点—三角面候选，并施加质量加权的分离速度约束。直接包含该顶点或与它共享拓扑边的面会被排除，实体、顶点、面和候选均按稳定顺序处理；桥接层只修改 Jolt 明确允许外部控制的顶点速度，不直接改写内部位置或包围盒。

`RenderFrameStats` 分别记录变形网格数、顶点数、三角形数、拒绝的无效网格、上传字节和上传耗时；Editor 的 Render 调试面板直接显示这些指标。没有固定物理子步的渲染帧会继续复用最近一次软体状态和 GPU 缓冲区，不会让布料闪退一帧。

Editor 选中软体实体时会在视口叠加约束拓扑：青色表示表面边，紫色表示参与四面体体积约束的边，黄色锚点表示固定顶点。播放期间叠加层直接使用最新模拟顶点，停止时使用资源静止姿态；边按顶点索引稳定排序，并将单实体显示上限限制为 4096 条。

## 预破碎破坏

M7 首版使用离线预破碎资产。`DestructibleAssetBaker` 接收已经分块的闭合凸网格、密度和局部变换，按 fragment ID 排序并生成稳定的 `asset#convex:<fragmentID>` 几何资源 ID；质量由闭合网格体积乘密度得到。未提供显式连接时，导入器先以变换后 AABB 筛选候选，再按顶点—三角面距离和可配置容差生成稳定连接图；显式连接优先，也可关闭自动生成。重复 ID、无效连接或容差、非有限顶点、越界索引和零体积几何会明确失败，不会生成替代 Box。初始连接图必须完全连通或完全无边；部分连通图会在烘焙时按 fragment ID 报告不可达碎块，运行时也会拒绝绕过烘焙器注入的无效图。烘焙结果可一次安装到 `MeshColliderGeometryResource` 与 `DestructibleAssetResource`；同一资源缩减碎块后重装会清理其 `#convex:` 命名空间内已淘汰的几何，同时保留无关共享几何。

场景实体通过 `Destructible` 引用资产，并配置累计伤害阈值、接触冲量阈值、单实体碎块预算、最大存活时间、休眠回收延迟和分离冲量。脚本可在 `onPrePhysics` 提交 `DestructionCommand`；直接命令会在本帧刚体同步前完成断裂，使新碎块参与当前固定步。Jolt 统一接触监听使用求解前速度与接触设置估算非零求解冲量，接触触发的断裂在该固定步结束后生成，下一固定步同步到 Jolt。

连接边可以覆盖伤害或冲量阈值；零值继承实体阈值。带 `worldPoint` 的非强制命令以两端碎块原点的世界空间中点作为连接锚点，只打断距离最近的合格边，并以空碎块数组的 `connectionBreak` 事件报告尚未造成分离的增量断裂；不带命中点的命令用于全局/范围伤害，会打断全部合格边。距离相同时按 connection ID 决胜，累计伤害采用有限值饱和。运行时按 EntityID、命令序号、fragment ID 和 connection ID 稳定处理。连接图分离且每个碎块都提供独立 `renderMesh` 时，包含最小 fragment ID 的根岛继续由源实体承载：Collider 按碎块局部变换重建为 Compound，完整源网格隐藏并由运行时子级代理绘制保留碎块；脱离岛按 fragment ID 激活为动态碎块，岛内连接同时断开。后续强制命令或实体级阈值只释放剩余根岛，不会重复生成已经释放或因预算丢弃的碎块。缺少独立碎块网格的兼容资产仍采用全量激活，避免完整网格与碎块视觉重叠。本路线不实现运行时任意布尔切割。

全局 `DestructionSettingsResource` 限制活动碎块和逐帧事件容量；碎块预算按最小 fragment ID 稳定截断，并在事件中报告丢弃数量。碎块可按寿命、连续休眠时间或源实体删除回收。`DestructionEventFrameResource` 汇总断裂、失败、回收与容量溢出，`DestructionStateFrameResource` 另外区分部分/完全破碎并提供已释放、根岛保留及活动碎块 ID。Scene v2 和 Prefab v2 采用资产语义：过滤动态碎块与 `DestructibleRetainedFragment` 代理，并用断裂前快照恢复源刚体、碰撞体和可见网格；Prefab 不能以任一运行时碎块或代理为根。GameSave v2 采用运行快照语义：保存累计伤害、断裂连接、部分/完全状态、已释放 ID、Compound 源 Collider、代理层级、碎块归属、刚体速度/待处理力与冲量/睡眠状态，以及寿命和休眠回收的剩余预算，并在读档时重映射所有实体引用。源实体的 `Destructible` 策略同时支持 Editor Manifest v5 往返。

统一 `PhysicsDebugFrameResource` 按 source EntityID 和 connection ID 输出破坏连接的两端世界坐标、断裂标志及源断裂标志。Editor 选中 `Destructible` 时直接消费该帧：完整边和锚点显示绿色，断裂边和锚点显示红色，单实体最多绘制 4096 条连接。Inspector 可编辑全部破坏策略，并显示资产碎块/连接数及最新活动/断裂状态；AI 场景语义暴露资产 ID、阈值、预算和运行摘要。`destruction-fragments` 基准稳定激活指定数量的完整预破碎资产；`destruction-islands` 则保留每个源的根碎块并释放其余碎块，额外门禁部分/完全源数量、Compound 根岛、渲染代理和保留碎块数量。两者都独立检查激活耗时、固定步分位数、内存增长、活动碎块数和丢弃子步，并在 macOS CI 以 Release 配置运行 4096 碎块场景。

## 稳定性和序列化

- 车辆创建、删除、命令和状态按 `EntityID` 稳定排序。
- 发动机、档位、离合器和逐轮状态参与物理检查点哈希。
- 累计破坏伤害、部分/完全状态、断裂连接、已释放/根岛 fragment ID 和活动碎块映射参与物理检查点哈希；破坏命令纳入录制与回放。
- 即使运行时资源被调用方重排，破坏碎块、连接、预算截断和事件仍分别按 fragment ID 与 connection ID 归一化。
- 车辆配置支持 Scene v2 与 Editor Manifest v5 往返。
- C ABI v6 校验刚体、角色、载具和软体结构尺寸，并对规则网格、任意表面及四面体拓扑的无效配置返回明确错误。
- AI 场景语义包含载具、软体、布料、表面网格和预破碎资产的配置，以及可用的最新运行状态摘要。
- `cloth-64`、`soft-body-instances`、`destruction-fragments` 和 `destruction-islands` 基准分别门禁自碰撞 64×64 单布料、8 个 32×32 实例、批量完整破碎和增量连通岛释放。

## 当前边界

M5、M6 与 M7 已完成。M7 的生产边界是离线预破碎：导入流程负责提供闭合凸碎块、逐碎块渲染资源和连接图，运行时负责局部/全局伤害与冲量阈值、增量连接断裂、根岛 Compound 重建、确定性岛释放、预算、回收、事件、录制回放、Editor 与 AI 语义。缺少逐碎块渲染资源或包含无法表示为 Collider TRS 的碎块资产会回退到全量激活；不实现运行时任意布尔切割。
