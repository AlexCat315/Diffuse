# P9 物理系统优化实现总结

## 概述

P9 级别完成了物理系统的核心架构优化，将桥接型 Jolt 实现收敛为持久化缓存架构，并补充了 Trigger 事件系统和 Layer 基础架构。

## 1. 持久化 Body 缓存架构

### 问题

原始实现采用桥接模式，每帧 physics step 都：
- 遍历所有 Entity 收集 BodyDesc
- 全量同步到 Jolt World
- 调用 Jolt step
- 全量同步回场景

性能问题：
- O(n) 每帧遍历，n 为场景实体数
- 频繁创建/销毁 Jolt Body
- 大量冗余内存分配

### 解决方案

采用**事件驱动的增量更新架构**：

#### Zig 层 (`src/engine/physics/system.zig`)

```zig
const PhysicsEvent = union(enum) {
    entity_created: EntityId,
    entity_destroyed: EntityId,
    rigidbody_added: EntityId,
    rigidbody_removed: EntityId,
    collider_added: EntityId,
    collider_removed: EntityId,
    transform_changed: EntityId,
};

var g_physics_event_queue: std.ArrayListUnmanaged(PhysicsEvent) = .empty;
```

**核心流程**：
1. 实体创建/销毁、组件增删、Transform 变更时 → `enqueuePhysicsEvent()`
2. 每帧 `stepJolt()` 开始时 → `processPhysicsEvents()`
3. 增量更新 Jolt World → 只处理变更的 Body
4. 调用 `guava_jolt_context_step_incremental()` → 只同步 Dynamic Body

**接口变更**：
- 新增 `guava_jolt_context_add_or_update_body()` - 增量添加/更新单个 Body
- 新增 `guava_jolt_context_remove_body()` - 删除单个 Body
- 新增 `guava_jolt_context_step_incremental()` - 增量 step，无需全量 BodyDesc

#### C++ 层 (`src/engine/physics/jolt_bridge.cpp`)

`GuavaJoltContext` 维护 `body_records` 映射：
```cpp
std::unordered_map<uint64_t, BodyRecord> body_records;

struct BodyRecord {
  GuavaJoltBodyDesc desc{};
  JPH::BodyID body_id{};
};
```

**增量同步逻辑**：
```cpp
bool SyncExistingBody(const GuavaJoltBodyDesc &desc, float delta_seconds) {
  auto entry = body_records.find(desc.entity_id);
  if (entry == body_records.end()) {
    return CreateBody(desc);  // 新增 Body
  }

  if (!EqualShapeAndSettings(entry->second.desc, desc)) {
    RemoveBody(desc.entity_id);
    return CreateBody(desc);  // 形状变更，重建
  }

  if (!EqualPoseAndVelocity(entry->second.desc, desc)) {
    // 仅更新位置和速度
    body_interface.SetPositionRotationAndVelocity(...);
  }
  return true;
}
```

### 性能收益

- **静态物体**：创建后几乎零开销
- **动态物体**：每帧只同步位置和速度，O(m) m << n
- **内存分配**：大幅减少，只在实体变更时分配

## 2. Trigger 事件系统

### 功能

完整的事件回调机制：
- `TriggerEnter` - 触发器进入
- `TriggerStay` - 触发器持续
- `TriggerExit` - 触发器退出

### 实现

#### Zig 层

```zig
pub const TriggerEvent = struct {
    entity_a: EntityId,
    entity_b: EntityId,
    kind: TriggerEventKind,  // enter/stay/exit
};

var g_trigger_event_queue: std.ArrayListUnmanaged(TriggerEvent) = .empty;
var g_trigger_callback: ?*const fn (TriggerEvent) void = null;

pub fn setTriggerCallback(callback: ?*const fn (TriggerEvent) void) void {
    g_trigger_callback = callback;
}
```

#### C++ 层

自定义 `GuavaContactListener` 继承 `JPH::ContactListener`：
```cpp
class GuavaContactListener final : public JPH::ContactListener {
  void OnContactAdded(...) override {
    if (body1.IsSensor() || body2.IsSensor()) {
      GuavaTriggerEvent event{entity_a, entity_b, 0};  // enter
      GuavaJoltEnqueueTriggerEvent(&event);
    }
  }
  
  void OnContactPersisted(...) override { /* stay */ }
  void OnContactRemoved(...) override { /* exit */ }
};
```

**线程安全**：C++ 层通过 `export fn GuavaJoltEnqueueTriggerEvent` 调用 Zig 层，使用互斥锁保护事件队列。

### 使用方式

```zig
// 注册回调
physics.setTriggerCallback(struct {
    fn onTrigger(event: physics.TriggerEvent) void {
        switch (event.kind) {
            .enter => { /* 处理进入事件 */ },
            .stay => { /* 处理持续事件 */ },
            .exit => { /* 处理退出事件 */ },
        }
    }
}.onTrigger);

// 或者轮询方式
const events = physics.pollTriggerEvents();
defer physics.clearTriggerEvents();
```

## 3. Layer 系统扩展

### 目标

实现灵活的碰撞过滤机制：
- 每个 Collider 可配置 Layer ID
- 每个 Collider 可配置碰撞组 (bitmask)
- 只与匹配的 Layer 发生碰撞

### 实现

#### Zig 层

扩展 Collider 组件：
```zig
pub const BoxCollider = struct {
    half_extents: Vec3 = .{ 0.5, 0.5, 0.5 },
    center: Vec3 = .{ 0.0, 0.0, 0.0 },
    is_trigger: bool = false,
    layer_id: u16 = 0,        // P9 新增
    layer_group: u16 = 0xFFFF, // P9 新增
};
```

扩展 JoltBodyDesc：
```zig
const JoltBodyDesc = extern struct {
    // ... 原有字段
    layer_id: u16,      // P9 新增
    layer_group: u16,   // P9 新增
};
```

**Layer 数据收集**：
```zig
fn extractLayerInfo(entity: *const Entity) struct { id: u16, group: u16 } {
    if (entity.box_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    // 类似处理 sphere_collider 和 mesh_collider
}
```

#### C++ 层

在 `GuavaJoltBodyDesc` 中添加 layer 字段：
```cpp
struct GuavaJoltBodyDesc {
  // ... 原有字段
  uint16_t layer_id;
  uint16_t layer_group;
};
```

**TODO**：完整的 Layer 过滤需要在 C++ 层实现自定义 `ObjectLayerPairFilter` 和 `BroadPhaseLayerInterface`，根据 `layer_id` 和 `layer_group` 计算碰撞掩码。

### Constraints 层

添加约束描述结构：
```cpp
struct GuavaJoltConstraintDesc {
  uint64_t entity_id;
  uint8_t constraint_type;  // 0=point-to-point, 1=hinge, 2=slider, 3=distance
  uint64_t entity_a;
  uint64_t entity_b;
  float pivot_a[3];
  float pivot_b[3];
  float axis_a[3];
  float axis_b[3];
  float min_limit;
  float max_limit;
  uint8_t is_enabled;
};
```

在 `GuavaJoltContext` 中添加约束管理：
```cpp
std::unordered_map<uint64_t, JPH::TwoBodyConstraint *> constraint_records;

bool AddOrUpdateConstraint(const GuavaJoltConstraintDesc &desc);
bool RemoveConstraint(uint64_t entity_id);
```

### 使用方式

```zig
// 设置 Layer
entity.box_collider = .{
    .half_extents = .{0.5, 0.5, 0.5},
    .layer_id = 1,      // Player 层
    .layer_group = 0b1111,  // 与层 0-3 碰撞
};

// 地面不与其他地面碰撞
entity.box_collider = .{
    .half_extents = .{5.0, 0.5, 5.0},
    .layer_id = 2,      // Ground 层
    .layer_group = 0b101,  // 只与 Player 和 Items 碰撞
};
```

## 4. 性能统计扩展

在 `types.zig` 中添加 `PerformanceStats` 追踪：
- 帧时间、绘制调用、内存使用
- 物理 body 数量、接触点数
- 冗余绑定优化效果
- FPS 和帧时间计算

（详见 P2 图形 API 优化文档）

## 接口清单

### Zig 层公共 API

```zig
// 物理事件
pub fn initPhysicsEvents() void
pub fn deinitPhysicsEvents() void
pub fn enqueuePhysicsEvent(event: PhysicsEvent) void

// Trigger 事件
pub const TriggerEvent = struct { ... }
pub const TriggerEventKind = enum { enter, stay, exit }
pub fn setTriggerCallback(callback: ?*const fn (TriggerEvent) void) void
pub fn pollTriggerEvents() []const TriggerEvent
pub fn clearTriggerEvents() void

// World 生命周期
pub fn deinitWorld(world: *scene_mod.World) void

// Physics Step
pub const Config = struct { ... }
pub const StepStats = struct { ... }
pub fn step(world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats
```

### C++ 层导出函数

```cpp
// Body 管理
GuavaJoltContext* guava_jolt_context_create(const GuavaJoltStepConfig* config);
void guava_jolt_context_destroy(GuavaJoltContext* context);
bool guava_jolt_context_add_or_update_body(GuavaJoltContext* context, 
                                           const GuavaJoltBodyDesc* desc,
                                           float delta_seconds);
bool guava_jolt_context_remove_body(GuavaJoltContext* context, uint64_t entity_id);

// Physics Step
bool guava_jolt_context_step_incremental(GuavaJoltContext* context,
                                         float delta_seconds,
                                         uint32_t collision_steps,
                                         GuavaJoltBodyState* out_states,
                                         size_t state_capacity,
                                         GuavaJoltStepStats* out_stats);

// 兼容旧接口
bool guava_jolt_context_step(GuavaJoltContext* context,
                             const GuavaJoltBodyDesc* in_bodies,
                             size_t in_body_count,
                             const GuavaJoltStepConfig* in_config,
                             GuavaJoltBodyState* out_states,
                             size_t in_state_capacity,
                             GuavaJoltStepStats* out_stats);

// Trigger 事件回调
void GuavaJoltEnqueueTriggerEvent(const GuavaTriggerEvent* event);
```

## 文件变更

### 修改的文件

- `src/engine/physics/system.zig` - 核心物理系统，事件驱动架构，添加约束支持
- `src/engine/physics/jolt_bridge.cpp` - Jolt C++ 桥接层，增量更新，约束管理
- `src/engine/scene/components.zig` - Collider 组件扩展 Layer 字段，添加 Constraint 组件
- `src/engine/render/renderer.zig` - 渲染器集成物理调试绘制
- `docs/physics_mvp_design.md` - 更新文档状态
- `docs/physics_p9_implementation.md` - P9 实现总结文档

### 新增文件

- `docs/physics_p9_implementation.md` - P9 实现总结（本文档）

## 性能对比

| 指标 | P8 桥接型 | P9 持久化 | 提升 |
|------|-----------|-----------|------|
| 每帧遍历 | O(n) | O(m) | m << n |
| Body 创建 | 每帧 | 仅变更时 | 大幅减少 |
| 内存分配 | 高频 | 低频 | 显著降低 |
| 静态物体开销 | 高 | 接近零 | 显著 |

n = 总实体数, m = 动态实体数

## 已知问题

1. **Layer 过滤不完整**：C++ 层还需实现自定义 `ObjectLayerPairFilter`，目前仅 Zig 层收集了 layer 数据

## 已完成功能

### Debug Draw 实现

- ✅ **物理形状可视化**：通过 `collectDebugShapes` 收集物理碰撞体信息
- ✅ **多形状支持**：支持 Box 和 Sphere 形状的线框绘制
- ✅ **Trigger 区分**：Trigger 碰撞体使用橙色 (0.92, 0.70, 0.30) 绘制，Solid 碰撞体使用绿色 (0.30, 0.92, 0.52) 绘制
- ✅ **集成渲染管线**：在渲染器的 `appendCollisionLines` 中集成物理调试绘制

### Constraints 实现

- ✅ **基础约束组件**：在 `components.zig` 中添加 `Constraint` 组件，支持四种类型：
  - Point-to-Point Constraint (0)
  - Hinge Constraint (1)
  - Slider Constraint (2)
  - Distance Constraint (3)
- ✅ **约束数据描述**：添加 `JoltConstraintDesc` 结构，包含约束参数（pivot、axis、limits 等）
- ✅ **C++ 桥接层**：在 `jolt_bridge.cpp` 中实现约束的创建、更新和删除
- ✅ **事件驱动管理**：在 `system.zig` 中添加约束事件（`constraint_added`/`constraint_removed`）
- ✅ **持久化管理**：约束随实体生命周期自动管理，支持动态启用/禁用

## 后续工作

### P10 计划

1. **完整 Layer 实现**
   - C++ 层实现碰撞过滤
   - 提供 Layer 配置 API
   - 优化 BroadPhase

2. **性能优化**
   - 更细粒度的事件过滤
   - Body 池化管理
   - 减少锁竞争

3. **高级约束功能**
   - 约束马达和驱动
   - 弹簧设置
   - 约束可视化

4. **物理查询 API**
   - 射线检测
   - 形状投射
   - 重叠检测

## 总结

P9 级别成功将物理系统从桥接型架构升级为持久化缓存架构，补充了 Trigger 事件系统和 Layer 基础架构。性能得到显著提升，为后续 Debug Draw 和 Constraints 功能打下了良好基础。
