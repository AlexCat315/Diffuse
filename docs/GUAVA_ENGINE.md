# Guava Engine — 功能推进文档

> **引擎语言**: Zig 0.15 | **平台**: macOS (Metal) → Windows (Vulkan/DX12 目标) → Linux (Vulkan 目标)
> **定位**: AI-Native 实时游戏引擎 + 离线物理渲染器（对标 Unity 编辑体验 + Blender Cycles 渲染品质）
> **上次更新**: 2026-03-30

---

## 目录

- [一、项目架构总览](#一项目架构总览)
- [二、已落地能力基线](#二已落地能力基线)
- [三、RHI 层重构 — 脱离 SDL3 图形 API](#三rhi-层重构--脱离-sdl3-图形-api)
- [四、光栅渲染管线 — 追平现代引擎基线](#四光栅渲染管线--追平现代引擎基线)
- [五、路径追踪渲染器 — 从 Demo 到生产品质](#五路径追踪渲染器--从-demo-到生产品质)
- [六、编辑器 UX — 响应式布局与创作工作流](#六编辑器-ux--响应式布局与创作工作流)
- [七、3D 创作工具链 — 对标 Blender 基础能力](#七3d-创作工具链--对标-blender-基础能力)
- [八、游戏运行时系统](#八游戏运行时系统)
- [九、AI-Native 基础设施](#九ai-native-基础设施)
- [十、分阶段执行路线图](#十分阶段执行路线图)
- [十一、开发纪律](#十一开发纪律)
- [十二、术语表](#十二术语表)

---

## 一、项目架构总览

### 1.1 系统分层

```
┌─────────────────────────────────────────────────────────────────┐
│                        Editor Shell                             │
│  Scene Hierarchy │ 3D Viewport │ Inspector │ AI Terminal        │
│  Asset Browser   │ Timeline    │ Post-Process │ Render Settings  │
├────────────────────────────┬────────────────────────────────────┤
│       Game Runtime         │         Creation Tools            │
│  SceneManager / GameState  │  Material Editor / Anim Graph     │
│  C# Script VM / WASM VM    │  UV Editor / Material Editor      │
│  Physics (Jolt)            │  Camera Sequencer                 │
│  Audio (SoLoud)            │  Post-Process Stack               │
│  Navigation (Recast)       │  Render Test / Golden Compare     │
├────────────────────────────┴────────────────────────────────────┤
│                     Rendering Engine                            │
│  ┌──────────────────────┐  ┌──────────────────────────────┐    │
│  │  Raster Pipeline     │  │  Path Tracer (Offline)       │    │
│  │  PBR + CSM + SSGI    │  │  GGX + MIS + NEE + OIDN     │    │
│  │  Bloom/TAA/FXAA/DOF  │  │  HDR Env + Principled BSDF  │    │
│  └──────────┬───────────┘  └──────────────┬───────────────┘    │
│             │      Shared Scene Data       │                    │
│  ┌──────────┴──────────────────────────────┴───────────────┐   │
│  │              RHI — 渲染硬件接口层 (自研)                 │   │
│  │   Metal Backend │ Vulkan Backend │ DX12 Backend (planned)│  │
│  │   + Compute     │ + Ray Tracing (Metal) │ + Indirect Draw│  │
│  └─────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  Platform │ Window (SDL3) │ Input (SDL3) │ File I/O │ Thread   │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 核心设计原则

1. **RHI 自研** — 图形通信用自己的抽象层面向 Metal/Vulkan/DX12，SDL3 只保留窗口/输入
2. **双轨渲染** — 实时光栅用于创作迭代，离线路径追踪用于影视级出图，共享同一场景数据
3. **AI 一等公民** — AI 通过 MCP 协议直接读写场景，所有操作进 Command 管道
4. **数据驱动** — 场景 JSON v6 序列化，Inspector 双向绑定，编译期反射
5. **渐进式品质** — 每个渲染特性可独立开关，degradation graceful

### 1.3 目标参照

| 参照系 | 对标能力 | 不做的事 |
|--------|---------|---------|
| **Unity** | 编辑器布局、组件工作流、Play/Pause/Stop、Asset Pipeline | C# 脚本生态、Asset Store |
| **Blender** | 路径追踪品质（Cycles）、材质编辑、相机动画、渲染输出 (4K 图片+视频) | 雕刻、绘制、流体模拟、视频编辑器 |
| **UE5** | 级联阴影、Lumen-级 GI 品质、多光源 | Nanite、World Partition、蓝图 |

---

## 二、已落地能力基线

### 2.1 渲染系统

| 能力 | 状态 | 说明 |
|------|------|------|
| RHI 层 | ✅ 自研 RHI | Metal / Vulkan 主路径已接入，SDL3 仅保留窗口与输入 |
| RenderGraph | ✅ | 通道依赖管理 |
| PBR + Cook-Torrance BRDF | ✅ | mesh.frag.glsl |
| IBL 环境光 (辐照度图 + BRDF LUT) | ✅ | CPU 为主，BRDF LUT 已有 GPU 路径 |
| 阴影 | ✅ 4-CSM + RT Shadow | 级联阴影已落地，RT 阴影已接入 |
| Depth Prepass / Skybox | ✅ | |
| Bloom / Tonemap / FXAA | ✅ | |
| SSAO | ✅ Compute | 已统一为 Compute 路径，HDR 合成已接入 |
| SSR | ⚠️ 屏幕空间反射 | HDR 主链已接回；roughness blur 仍待补 |
| DOF | ✅ CoC + 模糊 + 合成 | |
| TAA | ✅ 时域抗锯齿 | jitter、history resolve、正式 velocity buffer 已接入 drawFrame |
| 体积雾 | ✅ | |
| 光源 | ✅ 多光源 | 方向光 / 点光已在渲染路径中工作 |
| GPU RT | ✅ 影子 + 路径追踪 | Metal 路径已接入；其他平台仍在规划/回退 |
| CPU Path Tracer | ✅ | GGX VNDF + NEE/MIS + Principled BSDF + 俄罗斯轮盘 + 自适应 tile 采样 + 降噪导出 |
| Gizmo / Outline / ID Pass | ✅ | |
| 自动化渲染测试 | ✅ | 8 配置套件，Golden 对比 |

### 2.2 编辑器

| 能力 | 状态 |
|------|------|
| ImGui Docking 布局 | ✅ |
| Scene Hierarchy + Inspector | ✅ |
| Gizmo 变换工具 | ✅ |
| Material / Animation Editor | ✅ |
| Render Settings Panel | ✅ |
| Post-Process Editor | ✅ |
| Undo/Redo | ✅ |
| 多语言 i18n | ✅ |
| 响应式布局 | ✅ 状态栏平滑自适应 + 窄 Inspector 降级已落地 |

### 2.3 运行时系统

| 能力 | 状态 |
|------|------|
| Jolt Physics | ✅ 刚体/碰撞器/触发器/约束/Debug Draw |
| WASM VM | ✅ 热重载 + Inspector 参数反射，定位为 plugins / mods / tools |
| C# Script VM | ✅ NativeAOT 共享库加载 + `.csproj` 自动发布 + C# 源码热重载监听，定位为 NPC / UI / Gameplay |
| 骨骼动画 + Animation Graph | ✅ 60% |
| Audio (SoLoud) | ⚠️ 集成完成但仍有边界问题 | 初始化诊断已可用，仍需持续修复回归 |
| AssetRegistry + glTF 导入 | ✅ |
| 场景序列化 JSON v6 | ✅ |
| Prefab + ECS + BVH 空间索引 | ✅ |

### 2.4 AI-Native 基础设施

| 能力 | 状态 |
|------|------|
| MCP 协议 (stdio) | ✅ |
| 只读场景感知 | ✅ scene/entity/selection/editor context |
| CommandQueue 统一写入 | ✅ CRUD + 变换 + 层级 + 显隐 |
| Staged Transaction + Ghost Preview | ✅ |
| Query API (文本/组件/空间/BVH) | ✅ |
| Schema 资源族 | ✅ |

---

## 三、RHI 层重构 — 脱离 SDL3 图形 API

### 3.1 为什么必须重构

当前 RHI 已经从 SDL3 GPU 适配层中抽离出来；下面这段保留的是当初迁移时的目标与必须保留的约束：

| 限制 | 影响 |
|------|------|
| **无 Compute Shader** | IBL 预计算困在 CPU，SSAO/SSGI/GPU 剔除无法实现 |
| **无 Ray Tracing API** | Metal RT 走独立实现；Vulkan/DX12 RT 仍是后续目标 |
| **无 Indirect Draw** | GPU 驱动渲染不可能，大场景 draw call 无法压缩 |
| **仅 2D 纹理** | 立方体贴图用 6 张 2D 模拟，浪费内存 |
| **仅 Vertex + Fragment** | 无 Mesh Shader / Tessellation |
| **隐式同步** | 每帧 GPU 同步边界，compute dispatch 不可能异步 |
| **隐式 Pipeline Layout** | SDL3 自动推断 Descriptor Set 布局，引擎无法精确控制 GPU 资源绑定 |
| **隐式 Image Layout Transition** | SDL3 隐藏纹理状态转换，引擎无法插入显式 barrier |

> SDL3 将 Pipeline Layout 推断、Descriptor Set 分配、Image Layout Transition 全部藏在「驱动魔法」里。迁移到原生 API 意味着引擎必须**亲手管理**这三件事——这不是简单的 API 替换，而是一次架构升级。

### 3.2 新 RHI 架构

```
GuavaRHI (src/engine/rhi/)
├── rhi.zig                — 公共接口定义 (trait / vtable)
├── types.zig              — 统一类型 (Buffer, Texture, Pipeline, BindingSet, ResourceStates, ...)
├── command_buffer.zig     — 软件命令缓冲区 (ArrayList(u8) opcode stream)
├── state_tracker.zig      — 声明式资源状态追踪 (参考 NVRHI CommandListResourceStateTracker)
├── upload_ring.zig        — 分块子分配上传环 (staging buffer 管理)
├── queue.zig              — 多队列抽象 (Graphics / Compute / Transfer)
├── metal/
│   ├── metal_device.zig   — MTLDevice 封装 (Zig 调用 ObjC)
│   ├── metal_cmd.zig      — 软件 CommandBuffer → MTLCommandBuffer 翻译层
│   ├── metal_rt.zig       — Metal Ray Tracing (已有基础)
│   └── metal_shader.zig   — MTLLibrary / MSL 编译
├── vulkan/                — (Phase 2)
│   ├── vk_device.zig
│   ├── vk_cmd.zig         — 软件 CommandBuffer → VkCommandBuffer 翻译层
│   ├── vk_rt.zig          — VK_KHR_ray_tracing_pipeline
│   └── vk_shader.zig      — SPIR-V
└── dx12/                  — (Phase 3，可选)
```

**关键新增**：
- `command_buffer.zig` — CommandBuffer 为轻量软件对象而非硬件句柄（详见 3.4）
- `state_tracker.zig` — 声明式资源状态追踪，Pass 只声明目标状态，tracker 自动计算 barrier（参考 NVRHI，详见 3.7）
- `upload_ring.zig` — 分块子分配 staging buffer，版本化回收（参考 NVRHI UploadManager，详见 3.9）
- `queue.zig` — 显式多队列 + Timeline Semaphore 同步（详见 3.6）

### 3.3 RHI 公共接口

```zig
pub const RhiDevice = struct {
    // ============================================================
    //  A — 资源创建
    // ============================================================
    createBuffer:           *const fn(BufferDesc) Error!Buffer,
    createTexture:          *const fn(TextureDesc) Error!Texture,       // 支持 2D/3D/Cube/Array
    createSampler:          *const fn(SamplerDesc) Error!Sampler,
    createShaderModule:     *const fn(ShaderModuleDesc) Error!ShaderModule,

    // ============================================================
    //  B — 管线 & 绑定模型（三层架构，参考 NVRHI）
    //    Layer 1: BindingLayout — 编译期接口声明（对应 VkDescriptorSetLayout / D3D12 Root Signature）
    //    Layer 2: BindingSet    — 运行时资源绑定（对应 VkDescriptorSet / Descriptor Table）
    //    Layer 3: Bindless      — 可选动态数组（对应 Descriptor Indexing / ResourceDescriptorHeap）
    //    SDL3 在内部自动推断 Pipeline Layout / Descriptor Set，
    //    原生 API 必须由引擎显式创建。
    // ============================================================
    createBindingLayout:    *const fn(BindingLayoutDesc) Error!BindingLayout,   // Layer 1: slot 布局声明
    createBindingSet:       *const fn(BindingSetDesc, BindingLayout) Error!BindingSet,  // Layer 2: 需要 layout 参数
    createPipelineLayout:   *const fn(PipelineLayoutDesc) Error!PipelineLayout, // 组合多个 BindingLayout
    createGraphicsPipeline: *const fn(GraphicsPipelineDesc) Error!GraphicsPipeline,
    createComputePipeline:  *const fn(ComputePipelineDesc) Error!ComputePipeline,
    // 命令录制时绑定资源：
    setBindingSet:          *const fn(CommandBuffer, u32, BindingSet) void,  // slot, set

    // ============================================================
    //  C — 命令录制
    //    CommandBuffer 是软件 opcode 流（ArrayList(u8)），
    //    不是硬件句柄。见 3.6 节。
    // ============================================================
    createCommandBuffer:  *const fn() Error!CommandBuffer,
    beginRenderPass:      *const fn(CommandBuffer, RenderPassDesc) Error!RenderPassEncoder,
    beginComputePass:     *const fn(CommandBuffer) Error!ComputePassEncoder,
    beginCopyPass:        *const fn(CommandBuffer) Error!CopyPassEncoder,
    endRenderPass:        *const fn(RenderPassEncoder) void,
    endComputePass:       *const fn(ComputePassEncoder) void,
    endCopyPass:          *const fn(CopyPassEncoder) void,

    // ============================================================
    //  D — 同步 & 屏障
    //    SDL3 隐藏了所有 Image Layout Transition。
    //    原生 API 中，如果 SSAO 写完 texture 后
    //    直接被 base_pass 采样而不插 barrier → GPU 崩溃。
    //
    //    双层设计（参考 NVRHI）：
    //    低层: pipelineBarrier — RHI 原语，Render Graph 内部使用
    //    高层: StateTracker — 声明式 API，Pass 作者使用（见 3.7）
    // ============================================================
    pipelineBarrier:     *const fn(CommandBuffer, BarrierDesc) void,

    // ============================================================
    //  E — Swapchain & 呈现
    //    SDL3 的 submitFrame 在内部完成了
    //    CAMetalLayer drawable 获取 + present。
    //    原生 API 必须拆成三步。
    // ============================================================
    acquireSwapchainImage: *const fn() Error!SwapchainImage,
    submitCommandBuffer:   *const fn(Queue, CommandBuffer, SubmitDesc) Error!void,
    present:               *const fn(SwapchainImage) Error!void,

    // ============================================================
    //  F — 绘制 & Dispatch
    // ============================================================
    drawIndexed:         *const fn(RenderPassEncoder, DrawIndexedArgs) void,
    drawIndirect:        *const fn(RenderPassEncoder, Buffer, u32, u32) void,
    dispatch:            *const fn(ComputePassEncoder, u32, u32, u32) void,
    dispatchIndirect:    *const fn(ComputePassEncoder, Buffer, u32) void,

    // ============================================================
    //  G — Ray Tracing（可选能力）
    // ============================================================
    createAccelStructure:  *const fn(AccelStructureDesc) Error!AccelStructure,
    buildAccelStructure:   *const fn(CommandBuffer, AccelStructure) void,
    traceRays:             *const fn(ComputePassEncoder, RtPipelineState, u32, u32) void,

    // ============================================================
    //  H — 资源上传 / 回读
    // ============================================================
    uploadBufferData:  *const fn(Buffer, []const u8) void,
    uploadTextureData: *const fn(Texture, []const u8, u32) void,
    readbackTexture:   *const fn(Texture) Error![]u8,

    // ============================================================
    //  I — 队列获取（见 3.7 多队列）
    // ============================================================
    getQueue: *const fn(QueueClass) Error!Queue,

    // ============================================================
    //  J — 能力查询
    // ============================================================
    capabilities: Capabilities,
};

pub const QueueClass = enum { graphics, compute, transfer };

/// 统一资源状态位标志（参考 NVRHI ResourceStates）。
/// 抽象了 Vulkan 的 VkImageLayout + VkAccessFlags2 + VkPipelineStageFlags2 三个概念，
/// 后端用集中式查找表将每个位映射到平台三元组 (stage, access, layout)。
pub const ResourceStates = packed struct(u32) {
    constant_buffer:    bool = false,
    vertex_buffer:      bool = false,
    index_buffer:       bool = false,
    indirect_argument:  bool = false,
    shader_resource:    bool = false,
    unordered_access:   bool = false,
    render_target:      bool = false,
    depth_write:        bool = false,
    depth_read:         bool = false,
    copy_dest:          bool = false,
    copy_source:        bool = false,
    present:            bool = false,
    accel_struct_read:  bool = false,
    accel_struct_write: bool = false,
    resolve_dest:       bool = false,
    resolve_source:     bool = false,
    _padding: u16 = 0,
};

pub const Capabilities = struct {
    compute: bool,
    ray_tracing: bool,
    indirect_draw: bool,
    mesh_shaders: bool,
    texture_3d: bool,
    texture_cube_native: bool,
    max_queues: [3]u8,   // [graphics, compute, transfer] 各有几条硬件队列
};
```

**与旧版差异总结：**

| 旧 3.3 | 新 3.3 | 原因 |
|---------|--------|------|
| 无绑定模型 | 三层：`BindingLayout`(布局) → `BindingSet`(绑定) → Bindless(可选) | 参考 NVRHI 三层架构；Layout 不变性允许后端激进缓存 |
| `submitFrame` 包办一切 | `acquireSwapchainImage` → `submitCommandBuffer` → `present` 三步 | 必须拆开才能控制 Metal drawable / Vulkan swapchain |
| 无 barrier | `pipelineBarrier` (低层) + `StateTracker` (高层声明式) | 参考 NVRHI 双层 barrier 设计 |
| 无状态枚举 | `ResourceStates` 位标志统一抽象 stage/access/layout | 参考 NVRHI；后端用查找表映射到平台三元组 |
| 无队列概念 | `getQueue(.graphics / .compute / .transfer)` | 多队列并行是性能基础 |
| `beginFrame` 返回 CommandBuffer | `createCommandBuffer` 独立于帧 | 软件 cmd buf 可在任意线程录制 |

### 3.4 软件命令缓冲区（Software Command Buffer）

**核心设计**：`CommandBuffer` 不是硬件句柄（`VkCommandBuffer` / `MTLCommandBuffer`），而是一个 `ArrayList(u8)` opcode 流。

```zig
// command_buffer.zig — 平台无关
pub const CommandBuffer = struct {
    opcodes: std.ArrayList(u8),   // 编码后的指令流
    arena: std.mem.Allocator,     // 帧级 arena，帧末批量释放

    pub fn encodeBeginRenderPass(self: *CommandBuffer, desc: RenderPassDesc) void { ... }
    pub fn encodeSetBindGroup(self: *CommandBuffer, slot: u32, group: BindGroup) void { ... }
    pub fn encodeDrawIndexed(self: *CommandBuffer, args: DrawIndexedArgs) void { ... }
    pub fn encodePipelineBarrier(self: *CommandBuffer, desc: BarrierDesc) void { ... }
    pub fn encodeDispatch(self: *CommandBuffer, x: u32, y: u32, z: u32) void { ... }
    // ... 更多 encode 方法
};
```

**提交时（平台后端）**才翻译为硬件调用：

```zig
// metal/metal_cmd.zig
pub fn translateAndSubmit(queue: MTLCommandQueue, soft_buf: *const CommandBuffer) void {
    const hw_buf = queue.commandBuffer();
    var decoder = OpcodeDecoder.init(soft_buf.opcodes.items);
    while (decoder.next()) |op| {
        switch (op) {
            .begin_render_pass => |desc| { ... },  // MTLRenderCommandEncoder
            .set_bind_group    => |b|    { ... },  // setFragmentTexture / setVertexBuffer
            .draw_indexed      => |args| { ... },  // drawIndexedPrimitives
            .pipeline_barrier  => |b|    { ... },  // MTLFence / memoryBarrier
            .dispatch          => |d|    { ... },  // MTLComputeCommandEncoder.dispatch
            // ...
        }
    }
    hw_buf.commit();
}
```

**为什么这很重要？**

1. **并行录制** — `job_system.zig` 的 worker 线程各自录制独立的软件 CommandBuffer，无锁。录制完毕后，主线程按顺序将它们提交给后端翻译线程。
2. **跨平台统一** — 上层只看到 `CommandBuffer`（一段 bytes），不区分 Metal / Vulkan / DX12。
3. **可调试** — opcode stream 是纯数据，可以序列化、回放、diff，做 render replay 天然简单。

### 3.5 迁移策略 — Render Graph 驱动的架构升级

> ⚠️ "18 个渲染 Pass 零修改"是危险的幻想。SDL3 在幕后做了 Pipeline Layout 推断、Descriptor Set 分配、Image Layout Transition 三件大事。切到原生 API 时，这三件事全部暴露出来——18 个 Pass **全部需要适配**。
>
> 正确姿势：**把迁移视为一次 Render Graph 全面升级**，而非 API 表面替换。

#### 3.5.1 Render Graph 已有基础

当前 `render_graph.zig` 已实现：

| 能力 | 状态 |
|------|------|
| `QueueClass`（graphics / compute / copy） | ✅ 已有 |
| `ResourceAccess`（read / write / read_write） | ✅ 已有 |
| `DependencyEdge` + `cross_queue` 标记 | ✅ 已有 |
| `ResourceLifetime`（first_use_pass / last_use_pass） | ✅ 已有 |
| `compile()` 拓扑排序 + 依赖计算 | ✅ 已有 |
| DOT / JSON 图导出 | ✅ 已有 |
| **自动 barrier 插入** | ✅ 已有 `BarrierPlan`，并可编码为 `pipelineBarrier` |
| **transient 资源别名分配** | ❌ 缺失 — lifetime 已计算但未用于内存复用 |

#### 3.5.2 升级路线

| 阶段 | 内容 | 核心工作 |
|------|------|---------|
| **RHI-0** | Render Graph barrier 生成 | `compile()` 输出的 `DependencyEdge` → 自动生成 `BarrierDesc`，编码进 soft CommandBuffer |
| **RHI-1** | Metal Graphics Backend + 绑定模型 | `MTLDevice` 封装；每个 Pass 声明 `BindGroupDesc`（替代 SDL3 隐式推断）；`PipelineLayout` 静态定义 |
| **RHI-2** | Metal Compute Backend | `MTLComputeCommandEncoder`；IBL/SSAO 部分迁移到 Compute Queue |
| **RHI-3** | Metal RT 统一 | 将 `metal_rt_bridge.mm` 收归 RHI，复用 soft CommandBuffer |
| **RHI-4** | Vulkan Graphics Backend | 与 RHI-1 并行；`VkPipelineLayout` / `VkDescriptorSet` 映射 `BindGroup` |
| **RHI-5** | Vulkan Compute + RT | `VK_KHR_ray_tracing_pipeline` |

**每个 Pass 的适配清单**（以 `base_pass` 为例）：

```
1. 声明 PipelineLayoutDesc:
   - set 0: 全局 UBO (camera, lights)
   - set 1: 材质 BindGroup (albedo, normal, metallic_roughness)
   - set 2: per-object UBO (model matrix)

2. 在 Render Graph 声明 inputs / outputs:
   - inputs:  [shadow_map: read, depth: read]
   - outputs: [scene_color: write]

3. Render Graph compile() 自动插入 barrier:
   - shadow_map: write→read transition (在 shadow_pass 之后)
   - depth: write→read transition (在 depth_prepass 之后)
```

**SDL3 保留范围**：窗口创建、输入事件、音频设备、文件对话框。**不再用于任何图形调用。**

### 3.6 显式多队列（Explicit Multi-Queue）

```zig
// queue.zig
pub const Queue = struct {
    class: QueueClass,
    handle: *anyopaque,  // MTLCommandQueue* / VkQueue

    pub fn submit(self: Queue, cmd: CommandBuffer, desc: SubmitDesc) Error!void { ... }
};

pub const SubmitDesc = struct {
    wait_semaphores:   []const Semaphore = &.{},  // 提交前等待
    signal_semaphores: []const Semaphore = &.{},  // 提交后通知
};
```

典型帧流水线：

```
Graphics Queue ──┬── shadow_pass ── depth_prepass ── base_pass ── post_process ── present
                 │
Compute Queue  ──┴── IBL_prefilter ──── SSAO_compute ───▶ signal semaphore
                                                              │
                 (Graphics Queue base_pass wait ◀─────────────┘)
                 │
Transfer Queue ── texture_upload (streaming) ── signal fence for next frame
```

**实际调度**：`render_graph.zig` 的 `compile()` 输出带 `queue: QueueClass` 的 `CompiledPass`。运行时按 queue 分组，每组生成独立 soft CommandBuffer，提交到对应硬件队列，跨队列依赖用 `Semaphore` 同步。

**收益**：Path Tracer / IBL 预计算在 Compute Queue 运行时，Graphics Queue 保持 60fps 不卡顿。纹理流式加载在 Transfer Queue 异步进行。

### 3.7 Render Graph 驱动的自动 Barrier

没有 Render Graph 的辅佐，原生的 Vulkan/Metal RHI 在大型项目中根本无法存活——手动管理 18+ Pass 之间的资源状态转换是不现实的。

**自动化流程**：

```
Pass 声明 (inputs / outputs)
        │
        ▼
compile() 拓扑排序 + 依赖边计算
        │
        ▼
DependencyEdge[] — 每条边包含:
  from_pass, to_pass, resource, previous_access, next_access, cross_queue
        │
        ▼
Barrier 翻译器（新增）:
  对每条 DependencyEdge 生成 BarrierDesc:
    - read→write:  { src_stage: fragment, dst_stage: color_output, transition: shader_read → color_attachment }
    - write→read:  { src_stage: color_output, dst_stage: fragment, transition: color_attachment → shader_read }
    - cross_queue:  额外插入 queue_ownership_transfer + semaphore
        │
        ▼
编码到 soft CommandBuffer (encodePipelineBarrier)
        │
        ▼
后端翻译:
  Metal  → MTLFence + memoryBarrier scope
  Vulkan → vkCmdPipelineBarrier2
  DX12   → ResourceBarrier
```

**Pass 作者不需要知道 barrier 存在** — 他们只声明 "我读 shadow_map，我写 scene_color"，Render Graph 处理一切。

### 3.8 着色器编译策略

| 平台 | 着色器源 | 编译路径 |
|------|---------|---------|
| Metal | GLSL → SPIR-V → MSL (spirv-cross) | 离线编译，打包 .metallib |
| Vulkan | GLSL → SPIR-V (glslang) | 离线编译，打包 .spv |
| DX12 | HLSL → DXIL (dxc) | 离线编译 |

统一着色器源使用 GLSL，通过 `zig build shaders` 编译为各平台格式。manifest.json 管理所有 shader variant。

### 3.9 工业参考：NVRHI 设计模式借鉴

> [NVRHI](https://github.com/NVIDIAGameWorks/nvrhi) 是 NVIDIA 开源的工业级 RHI 抽象层（D3D11 / D3D12 / Vulkan），被 RTX Remix 等项目使用。以下是 Guava RHI 从中提取的关键设计模式。

#### 3.9.1 采纳的设计

| NVRHI 模式 | Guava 对应 | 说明 |
|---|---|---|
| **三层绑定模型**：`BindingLayout` → `BindingSet` → Bindless | `createBindingLayout` → `createBindingSet(desc, layout)` | Layout 不变性允许后端激进缓存 VkPipelineLayout / Root Signature |
| **声明式状态追踪**：`setTextureState` + `commitBarriers` | `StateTracker.requireTextureState` + `commitBarriers` | Pass 只声明目标状态，tracker 自动计算 barrier |
| **`ResourceStates` 位标志** | `types.zig` 中的 `ResourceStates` packed struct | 统一抽象 Vulkan 三元组 (stage, access, layout)，后端用集中式查找表映射 |
| **`keepInitialState` / `permanentState`** | `TextureDesc.keep_initial_state` | 减少无谓 barrier：帧末自动恢复 / 静态资源零 barrier |
| **Barrier 合并** | `StateTracker` 同资源多次请求自动 OR 合并 | 减少 `vkCmdPipelineBarrier2` 调用次数 |
| **统一 CommandList + 队列类型参数** | 统一 `CommandBuffer` soft opcode stream + `QueueClass` | NVRHI 用一个 ICommandList，队列类型决定可用方法 |
| **分块上传管理器**（UploadManager） | `upload_ring.zig` | 64KB 分块子分配 + 版本化回收，Timeline Semaphore 驱动 |
| **Per-subresource 状态追踪** | `StateTracker` 支持 `SubresourceSet` 粒度 | Bloom downsample chain 可以 mip 0 写/mip 1-N 读 |

#### 3.9.2 上传环设计（参考 NVRHI UploadManager）

```zig
// upload_ring.zig
pub const UploadRing = struct {
    const Chunk = struct {
        buffer: Buffer,             // staging buffer (CPU-visible)
        cpu_ptr: [*]u8,             // mapped pointer
        offset: usize,              // current write cursor
        capacity: usize,            // chunk size (default 64KB)
        version: u64,               // frame version when last used
    };

    chunks: std.ArrayList(Chunk),
    free_chunks: std.ArrayList(*Chunk),
    current: ?*Chunk,
    frame_version: u64,
    chunk_size: usize = 64 * 1024,

    /// 从当前 chunk 子分配 size 字节。如果当前 chunk 空间不足，
    /// 尝试复用空闲 chunk，否则创建新 chunk。
    pub fn suballocate(self: *UploadRing, size: usize, alignment: usize) Error!SubAlloc {
        // 1. 尝试 current chunk
        // 2. 尝试 free_chunks (version <= completed_version)
        // 3. 创建新 chunk
    }

    /// 帧结束时调用。通过 Timeline Semaphore 查询已完成的帧版本，
    /// 将对应 chunk 回收到 free_chunks。
    pub fn onFrameComplete(self: *UploadRing, completed_version: u64) void { ... }
};

pub const SubAlloc = struct {
    cpu_ptr: [*]u8,     // CPU 写入地址
    gpu_offset: u64,    // GPU 端偏移（用于 copy 命令）
    buffer: Buffer,     // 所在的 staging buffer
};
```

#### 3.9.3 与 NVRHI 的差异

| 方面 | NVRHI | Guava | 选择理由 |
|------|-------|-------|----------|
| **生命周期管理** | `RefCountPtr` 引用计数 | 确定性 `destroy` + 帧级 arena | Zig 无 GC，确定性释放更可预测 |
| **Descriptor Pool 策略** | Vulkan: 每 BindingSet 1 个 pool | 全局 pool + free list 回收 | 1:1 策略浪费内存，全局 pool 复用率更高 |
| **Swapchain** | 不在核心接口 | `acquireSwapchainImage` / `present` 在核心接口 | 避免各平台碎片化处理 |
| **CommandBuffer** | 直接映射硬件 CommandBuffer | 软件 opcode stream | 支持并行录制 + render replay |
| **跨队列 barrier** | `VK_QUEUE_FAMILY_IGNORED` | Render Graph `cross_queue` 边生成 ownership transfer | NVRHI 不做队列所有权转移是简化；Guava 需要多队列 |
| **Bindless** | 完整 DescriptorTable 支持 | Phase 2 实现 | 逐步演进，先满足当前 18 Pass |
| **状态映射表** | `g_ResourceStateMap[]` 集中式查找表 | 同样用 comptime 查找表 | Zig comptime 可在编译期生成映射，零运行时开销 |

> **⚠️ 设计提醒**: 自研 RHI 拥抱 Bindless 优先设计，不要试图模拟旧式槽位绑定。现代 GPU API（Metal 3.1+ / Vulkan 1.2+ / DX12）原生支持 Descriptor Indexing，过度抽象会导致性能回退到"最低公分母"。

---

## 四、光栅渲染管线 — 追平现代引擎基线

### 4.1 当前差距诊断

| 问题 | 根因 | 视觉影响 |
|------|------|---------|
| 画面"平"，无空间感 | 全局 ambient 是常量，无间接光 | 致命 — 缺少颜色溢出和反弹光 |
| 远处阴影块状 | 已切换为 4-CSM，仍可继续优化远景稳定性 | 中等 — 级联边界和精度仍需打磨 |
| 无环境遮蔽 | SSAO 已接入主渲染链并合成到 HDR | 低 — 已有接地感，仍可继续优化质量 |
| 场景光照单调 | 多光源已接入渲染路径 | 低 — 复杂灯光布局仍需继续完善 |
| 锯齿明显 | TAA 已接入 drawFrame，含正式 velocity buffer；后续主要是 ghosting 质量打磨 | 低 — 边缘闪烁已显著缓解 |
| 纹理物体黑色 | bind group slot_offset 问题 | 致命 — 基础功能损坏 |

### 4.2 光栅主链（已落地）

当前主渲染顺序如下：

```
渲染 Pass 顺序:
1. Shadow Map (4-级 CSM + 点光 Cube Shadow)
2. Depth Prepass
3. G-Buffer / Base Pass (PBR + 多光源 + SSAO 接入 + CSM 阴影)
4. SSAO (32 样本 → 写入 AO 纹理)
5. SSGI (屏幕空间 GI — 补充间接光)
6. SSR (分层模糊 — 粗糙度驱动)
7. Volumetric Fog
8. Skybox
9. RT Shadow Composite (可选)
10. TAA (Halton jitter + history blend + velocity)
11. Bloom
12. DOF
13. Tonemap + Color Grading
14. FXAA (TAA 关闭时的后备)
15. Gizmo / Outline / UI Overlay
```

### 4.3 逐项实施清单

#### R-1 修复纹理绑定（紧急）
- [x] 审计 mesh_pass.zig bind group slot_offset 与 mesh.frag.glsl set=2 的对齐
- [x] 验证所有 bind group 创建路径的 slot 正确性
- [x] 场景中放置带贴图物体，确认不再渲染为黑色
- [x] 修复 main.zig GPA defer 顺序导致的 false-positive 内存泄漏（render-test 退出码 1）
- **验收**: ✅ slot_offset 审计通过（0-4材质/5阴影/6-9 IBL），render-test 套件存在，golden 需维护

#### R-2 SSAO 接入光照
- [x] renderer.zig 增加 ssao_composite_pass（复用 RtShadowCompositePass 乘法混合管线）
- [x] SSAO 渲染后通过 overlay pass 将遮蔽纹理叠加到 HDR 缓冲
- [x] 更新 SSAO golden image（avg brightness 0.889→0.232，遮蔽生效）
- **验收**: ✅ render-test ssao 配置通过，角落/接缝处明显变暗

#### R-3 级联阴影贴图 (CSM)
- [x] ShadowMapState 已切到 4 级级联（4 张独立 depth texture）
- [x] 计算每级投影矩阵：基于视锥体 practical split scheme
- [x] mesh.frag.glsl 已按片元 view-depth 选择级联并做级联边界混合
- [x] shadow_pass.zig 已按 4 个 cascade 分别渲染
- **验收**: ✅ 4-CSM 主链已工作；近处清晰度与远景稳定性已明显提升，后续仍可继续打磨 bias / split 参数

#### R-4 多光源支持
- [x] BasePassUniforms 已改用数组: `directional_lights[4]`, `point_lights[16]`, `spot_lights[16]`
- [x] mesh.frag.glsl 已循环遍历活跃光源累加 radiance
- [x] PreparedScene / BasePass 已收集并裁剪场景灯光
- **验收**: ✅ 多光源主链可用；方向光 / 点光 / 聚光灯已能同时参与光照

#### R-5 TAA 完整接入
- [x] 投影矩阵已注入 Halton 2,3 序列 jitter（每帧不同）
- [x] 历史纹理管理已接入，并在 resize / 相机变化时 seed / invalidate
- [x] taa_pass.zig 已实现 neighborhood clamp + history blend
- [x] 已新增正式 velocity buffer：`velocity_pass.zig` + `velocity.vert/frag.glsl`
- [x] 渲染顺序已放在 Tonemap 之前
- **验收**: ✅ jitter、history resolve、velocity 主链都已接通；相机与刚体物体运动的 TAA 重投影正式可用

#### R-6 屏幕空间 GI (SSGI)
- [x] 已改为 Compute 路径：`ssgi_compute_pass.zig` + `ssgi_compute.comp.glsl`
- [x] 从 depth buffer 重建视空间坐标，在屏幕空间 trace 短距离光线
- [x] 采样命中点颜色作为间接光贡献
- [x] 结果已通过 composite pass 混合回 HDR 主链
- **验收**: ✅ SSGI 主链已接通；颜色溢出和角落反弹光可通过 viewport 开关观察

#### R-7 SSR 粗糙度模糊
- [x] 已将 SSR 从旧 prototype pass 改为正式 fullscreen pass
- [x] renderer 已正式接回 HDR 主链：`ssr_texture` 生成后再 additive composite 回 HDR
- [x] 根据 roughness 对 SSR 结果做 cone tracing 模糊 / mip blur
- [x] 光滑表面清晰反射，粗糙表面模糊反射
- **验收**: ⚠️ SSR 已正式参与主链并可输出有效反射；roughness-aware blur 仍待补，故本项保持进行中

#### R-8 Contact Shadows
- [x] `contact_shadow_pass.zig` 已改为正式 fullscreen pass，不再走 output=0 的 prototype 空跑路径
- [x] 对每个片元沿光源方向做短距离 screen-space ray march
- [x] 输出到 `contact_shadow_texture` 并以乘法 composite 叠加回 HDR
- [x] 默认检测近距离接触区，可通过 viewport 参数调整范围 / 厚度 / 强度 / 步数
- **验收**: ✅ 物体底部已有额外接触阴影，可在后处理面板里直接调参数

#### R-9 渲染风格插件化系统
- [x] **设计目标**: 将渲染风格抽象为可插拔扩展，用户可导入自定义风格（如卡通 Cel Shading、中国水墨丹青），与内置默认 PBR 渲染并列管理。
- [x] **设计约束**: 渲染风格先以“类型化渲染扩展”落地，而不是直接与 `WASM VM` 共享 ABI、生命周期和运行时对象模型。

**分层原则**:
1. `PluginRegistry` 只负责插件来源、发现、版本/依赖检查、启停状态、错误记录。
2. `StyleRegistry` 负责 `render_style` 的类型化运行时数据，包括 shader program 选择、参数 schema、运行时参数值，以及与 `Renderer` 的绑定。
3. `Renderer` 仍是 GPU 资源与 Pass 执行的 owner；风格切换不能绕过 `Renderer` 直接改渲染拓扑。
4. `RenderGraph` 只有在执行器和资源语义成熟后，才承接用户自定义 `post_chain`；当前阶段只承担内置 Pass 的依赖表达，不承担任意用户 Pass 注入。

**风格描述结构（类型化载荷）**:
```zig
// src/engine/render/style_plugin.zig
pub const StylePluginManifest = struct {
    name: []const u8,
    display_name: []const u8 = "",
    version: []const u8 = "1.0.0",
    source: plugin_types.PluginSource = .builtin,
    path: ?[]const u8 = null,

    mesh_program: []const u8 = "mesh",
    shadow_program: ?[]const u8 = null,
    disabled_passes: []const []const u8 = &.{},
    config_schema: []const StyleParam = &.{},
    post_chain: []const StylePostPassDescriptor = &.{},
};

pub const StylePostPassDescriptor = struct {
    name: []const u8,
    shader_program: []const u8,
    stage: StylePassStage = .post_lighting,
    reads: []const []const u8 = &.{},
    writes: []const []const u8 = &.{},
    order_after: ?[]const u8 = null,
    order_before: ?[]const u8 = null,
};
```

`post_chain` 不是简单的 pass 名字列表；它至少要声明执行阶段、读写资源和排序约束，否则 `RenderGraph` 无法安全推导 barrier、资源别名和调度顺序。

**目录与来源约定**:
- `engine://<name>`: 内置风格。可由代码直接注册，也可由 `engine_plugins/<name>/` 提供 manifest。
- `user://<name>`: 用户本地实验插件，对应 `user_plugins/<name>/`，默认不随项目分发。
- `project://<name>`: 项目级插件，对应 `project_plugins/<name>/`，应随项目版本控制与打包。

```text
guava_engine/
├── engine_plugins/
│   └── default_pbr/
│       └── manifest.json
├── user_plugins/
│   └── cartoon_style/
│       ├── manifest.json
│       └── shaders/
└── project_plugins/
    └── ink_wash/
        ├── manifest.json
        └── shaders/
```

**Render Style Manifest 示例**:
```json
{
    "name": "cartoon_style",
    "version": "1.0.0",
    "plugin_type": "render_style",
    "source": "project",
    "dependencies": [],
    "render_style": {
        "display_name": "Cartoon Style",
        "mesh_program": "cartoon_mesh",
        "shadow_program": "shadow_pass",
        "disabled_passes": ["bloom", "taa"],
        "style_params": [
            {
                "name": "outline_width",
                "type": "float",
                "default": 1.5,
                "min": 0.0,
                "max": 4.0
            }
        ],
        "post_chain": [
            {
                "name": "edge_detection",
                "shader_program": "edge_detection",
                "stage": "post_lighting",
                "reads": ["hdr_color", "depth"],
                "writes": ["style_color"],
                "order_after": "ssr"
            }
        ]
    }
}
```

**阶段划分**:
1. **Phase A（当前阶段）**: 内置风格注册、风格切换、`disabled_passes` 查询、参数存储。
2. **Phase B**: 用户目录扫描、manifest 解析、shader 热重载、Inspector 参数面板。
3. **Phase C**: 基于 `StylePostPassDescriptor` 的自定义 `post_chain` 注入。该阶段依赖 `RenderGraph` 执行器与资源语义成熟后再做。

**与现有 WASM VM 关系**:
- `render_style` 不默认走 `WASM VM`；它是渲染扩展，不是脚本运行时实例。
- `WASM VM` 继续用于 plugins / mods / tools，尤其是逻辑、工具和编辑器扩展。
- 如需脚本参与风格工作流，脚本只作为导入、生成、调试工具，不直接持有 render pass 生命周期。

**验收标准**:
- [x] 引擎内置默认风格（等同于当前 PBR 渲染）
- [x] 用户插件可从 `user_plugins/` 或 `project_plugins/` 被扫描并导入
- [x] Viewport 工具栏可切换风格，实时重绘
- [ ] 风格参数可通过 Inspector 调节并持久化
- [x] 风格切换失败时可回滚到上一个有效风格

**当前实现状态**:
- `StyleRegistry` 已注册 2 个内置风格: `default_pbr`（PBR）、`unlit_flat`（Unlit Flat）
- `StylePluginManifest` 已支持: `source`（PluginSource）、`mesh_program`、`shadow_program`、`disabled_passes`、`config_schema`、`post_chain`（StylePostPassDescriptor 数组）
- `StylePostPassDescriptor` 已定义: name、shader_program、stage（StylePassStage）、reads/writes、order_after/order_before
- `StylePassStage` 枚举: post_lighting、post_tonemap、pre_ui
- `StyleParamValues` 运行时参数存储已就绪（per-style HashMap）
- `isPassDisabledByActiveStyle()` 已可供渲染管线查询
- `rollbackStyle()` 已实现：风格切换失败时可回滚到上一个有效风格
- `loadUserPlugin()` / `scanPluginDirectory()` 已完成 Phase B 实现：JSON 解析（`std.json.parseFromSlice`）、目录扫描（`PluginRegistry.discover()`）、类型化 loader 分发（`dispatchStylePlugins` / `dispatchScriptVmPlugins`）
- `StyleRegistry.unregister()` 已实现：per-style 内存释放（`StyleAlloc`）、活跃风格自动回退 `default_pbr`、参数值清理
- Per-style allocation tracking（`style_allocs: StringHashMap(StyleAlloc)`）已就绪，`unregister()` 和 `deinit()` 均正确释放
- `post_chain` 字段已可从 manifest 加载但尚未注入 RenderGraph（Phase C）

#### R-10 通用插件系统基础设施

> R-10 的目标不是“所有插件共用一个扁平 Manifest 和一个统一 ABI”，而是“统一公共外壳 + 类型化载荷 + 子系统持有运行时对象”。

**设计目标**: 统一插件来源、发现、依赖、版本兼容、生命周期与错误呈现，同时避免把渲染、音频、脚本 VM 的专有字段硬塞进一个平面结构。

**核心类型定义**:
```zig
// src/engine/plugin/types.zig

pub const PluginType = enum {
    render_style,
    audio_effect,
    physics_ext,
    terrain_gen,
    ai_behavior,
    ui_extension,
    script_vm,
};

pub const PluginCapability = enum {
    shader,
    compute_pass,
    render_pass,
    audio_processor,
    script_handler,
};

pub const PluginSource = enum {
    builtin,
    user,
    project,
};
```

**统一公共外壳，类型化载荷单独承载**:
```zig
// 公共外壳：所有插件共享
pub const PluginManifest = struct {
    name: []u8,
    version: PluginVersion,
    plugin_type: PluginType,
    capabilities: []const PluginCapability = &.{},
    source: PluginSource = .user,
    path: []u8 = &.{},
    dependencies: []const []const u8 = &.{},
};

// 类型化载荷：按 plugin_type 分发解析
pub const PluginPayload = union(PluginType) {
    render_style: StylePluginManifest,
    script_vm: WasmPluginManifest,
    audio_effect: AudioEffectManifest,
    physics_ext: PhysicsPluginManifest,
    terrain_gen: TerrainPluginManifest,
    ai_behavior: AiBehaviorManifest,
    ui_extension: UiExtensionManifest,
};

pub const PluginRecord = struct {
    manifest: PluginManifest,
    lifecycle: PluginLifecycle,
    last_error: ?[]const u8 = null,
};
```

`PluginCapability` 是查询标签，不是类型 schema 的替代品。比如 `render_style` 仍然必须走 `StylePluginManifest`，不能只靠 `capabilities = [shader, render_pass]` 描述完整语义。

**推荐加载流程**:
1. 扫描 `engine_plugins/`、`user_plugins/`、`project_plugins/`，构建候选清单。
2. 解析公共 `PluginManifest`，完成版本和依赖检查。
3. 按 `plugin_type` 分发到类型化 loader，解析 `PluginPayload`。
4. `PluginRegistry` 注册 `PluginRecord`，记录状态、错误和来源。
5. 对应子系统接管运行时对象。
   - `StyleRegistry` 持有 render style 的 shader/参数/激活状态。
   - 脚本子系统持有 `WasmPlugin` 或其他 VM 实例。
   - 音频/物理等各自子系统持有本类型运行时对象。

**插件注册表职责**:
```zig
// src/engine/plugin/registry.zig
pub const PluginRegistry = struct {
    plugins: std.StringHashMap(*PluginRecord),
    by_type: std.AutoArrayHashMap(PluginType, std.ArrayList(*PluginRecord)),
    capabilities: std.AutoArrayHashMap(PluginCapability, std.ArrayList(*PluginRecord)),

    pub fn discover(self: *PluginRegistry, root_path: []const u8) !void { ... }
    pub fn enable(self: *PluginRegistry, name: []const u8) !void { ... }
    pub fn disable(self: *PluginRegistry, name: []const u8) !void { ... }
    pub fn unload(self: *PluginRegistry, name: []const u8) !void { ... }
    pub fn getByType(self: *const PluginRegistry, plugin_type: PluginType) []const *PluginRecord { ... }
    pub fn getWithCapability(self: *const PluginRegistry, cap: PluginCapability) []const *PluginRecord { ... }
};
```

`PluginRegistry` 不直接拥有 GPU Pass、Shader Module、WASM Instance 这类重资源对象；它管理的是插件元数据、状态和跨类型查询。

**与现有系统关系**:
| 现有系统 | 在插件架构中的角色 |
|---------|-------------------|
| `WASM VM` | `script_vm` 类型的 loader 与运行时宿主 |
| `StyleRegistry` | `render_style` 的运行时 owner |
| Asset Library | 目录扫描、文件监听、热重载基础设施 |
| `RenderGraph` | 未来为 `render_style.post_chain` 提供执行后端；当前不作为统一插件运行时 |

**验收标准**:
- [x] `PluginType` / `PluginCapability` / `PluginSource` 枚举定义完成
- [x] `PluginRegistry` 支持按类型和能力查询
- [x] 插件依赖版本兼容性检查
- [x] 生命周期管理（load / enable / disable / unload）
- [x] Editor Plugin Manager 面板显示所有已发现插件
- [x] `PluginManifest` 重构为公共外壳，`PluginRecord` 替代原 `Plugin`

**当前实现状态**:
- `PluginType`、`PluginCapability`、`PluginSource`、`PluginLifecycle` 已完成（`src/engine/plugin/types.zig`）
- `PluginVersion.parse()` + `compatible()` 主版本兼容性检查已完成（含单元测试）
- `PluginManifest` 已重构为公共外壳：移除了 `shaders`/`post_passes` 等类型化字段，保留 name、version、plugin_type、capabilities、source、path、dependencies、hooks
- `PluginRecord` 已新增（替代原 `Plugin`）：包含 manifest + lifecycle + last_error，附带 `setLastError()` / `clearLastError()` / `hasError()` 查询
- `PluginRegistry` 已支持：按 name/type/capability 查询、`enable()`/`disable()`/`unload()` 生命周期流转
- `PluginRegistry.discover()` 已实现目录扫描：遍历子目录、读取 `manifest.json`、调用 `parseManifest()` 并注册 `PluginRecord`
- `manifest.zig` 提供统一 `parseManifest()` 解析入口，使用 `std.json.parseFromSlice` API
- `Plugin` 类型保留为 `PluginRecord` 别名，确保向下兼容
- `Renderer` 作为统一插件编排层：`discoverPlugins()` → `dispatchStylePlugins()` + `dispatchScriptVmPlugins()`
- `Renderer.enablePlugin()` / `disablePlugin()` / `unloadPlugin()` / `rescanPlugins()` 生命周期方法已完成，含错误回写
- `script_vm` 类型已接入：`ScriptVmPluginLoader` 负责验证（检查 `main.zig` / `main.wasm`），实际加载由应用层驱动
- Editor Plugin Manager 面板已完成：6 列表格（Name/Type/Source/State/Actions/Error）、Enable/Disable/Unload 按钮（deferred action 安全模式）、Rescan 按钮
- 插件系统单元测试已覆盖：manifest 解析（valid/invalid JSON/missing fields/unknown type/unknown cap/extra fields）、registry 生命周期（register/enable/disable/unload）、error state、StyleRegistry（builtins/setActive/rollback/register/unregister/fallback/isPassDisabled）

#### R-11 渲染风格作为插件系统首个用例

R-11 的目标不是把 `StyleRegistry` 删除后硬塞进 `PluginRegistry`，而是把二者按职责正确接线。

**推荐接线方式**:
1. `PluginRegistry` 负责扫描目录并发现 `render_style` 类型插件。
2. `render_style` 类型化 loader 把 manifest 解析成 `StylePluginManifest`。
3. `Renderer` / `StyleRegistry` 接管运行时对象，注册风格、维护参数和值、处理激活切换。
4. Viewport 和 Inspector 通过 `StyleRegistry` 查询风格；Plugin Manager 通过 `PluginRegistry` 展示来源、状态、错误。
5. 只有当 `RenderGraph` 执行器真正成为权威调度器时，才接入用户自定义 `post_chain`。

**风格状态真源规则**:
- `StyleRegistry.active_style_name` 是运行时真源。
- `EditorViewportState.active_render_style` 是编辑器持久化缓存，用于保存上次选择。
- 编辑器启动或项目加载时，应从 `EditorViewportState` 回填到 `StyleRegistry`。
- UI 切换时，应先更新 `StyleRegistry`，再镜像回 `EditorViewportState`。

**当前代码形态**:
```zig
// src/engine/render/style_plugin.zig
pub const default_pbr_style = StylePluginManifest{
    .name = "default_pbr",
    .display_name = "PBR (Default)",
    .builtin = true,
    .mesh_program = "mesh",
    .shadow_program = "shadow_pass",
};

pub const unlit_flat_style = StylePluginManifest{
    .name = "unlit_flat",
    .display_name = "Unlit Flat",
    .builtin = true,
    .mesh_program = "mesh",
    .shadow_program = null,
    .disabled_passes = &.{ "bloom", "ssr" },
    .config_schema = &.{
        .{ .name = "opacity", .display_name = "Opacity", .default_value = 1.0 },
    },
};
```

**当前实现状态**:
- `Renderer` 持有 `style_registry` 字段，初始化时自动注册 2 个内置风格
- Viewport → View 菜单 → Render Style 区域动态列出所有已注册风格
- `StylePluginManifest` 已新增 `source`（PluginSource）、`post_chain`（StylePostPassDescriptor 数组）字段
- `StylePostPassDescriptor` + `StylePassStage` 类型已就绪，为 Phase C post_chain 注入做准备
- `isPassDisabledByActiveStyle(pass_name)` 已可供渲染管线按风格禁用/启用 Pass
- `rollbackStyle()` 已实现：风格切换失败时可回滚到上一个有效风格
- `StyleParamValues` per-style 参数运行时存储已就绪
- `PluginManifest` 已重构为公共外壳，`PluginRecord` 已替代原 `Plugin`
- `PluginRegistry` 已新增 `enable()`/`disable()`/`unload()` 生命周期流转
- `PluginRegistry.discover()` 已实现目录扫描并自动注册
- `ScriptVmPluginLoader` 已接入 `Renderer.dispatchScriptVmPlugins()`，验证 `script_vm` 插件
- `Renderer` 作为统一编排层：`enablePlugin` / `disablePlugin` / `unloadPlugin` / `rescanPlugins` 均已完成
- `PluginRegistry` → `StyleRegistry` 的类型化 loader 接线已完成（`dispatchStylePlugins` → `loadFromDiscoveredPlugin`）
- `StyleRegistry.unregister()` 已实现：per-style 内存释放 + 活跃风格回退
- Editor Plugin Manager 面板已完成：Rescan / Enable / Disable / Unload 按钮（deferred action 安全模式避免迭代时变更 HashMap）
- 插件系统单元测试已就绪（manifest 解析、registry 生命周期、style registry）

---

## 五、路径追踪渲染器 — 从 Demo 到生产品质

### 5.1 重写进度与剩余差距

> 2026-03 代码状态：CPU/Metal 路径追踪已完成 GGX VNDF 采样、cosine diffuse、NEE + power heuristic MIS、Principled BSDF（metallic / roughness / transmission / emissive）、normal / metallic-roughness / AO / emissive 贴图链路、HDR `.hdr` 环境重要性采样、俄罗斯轮盘、8x8 tile 自适应采样。编辑器 PathTrace PNG 导出已可输出 `albedo / normal` AOV sidecar，并按 `OIDN(动态加载) -> MPS Guided -> CPU Guided` 自动选择降噪后端；无 HDR 时环境贡献归零，Render Output 已可在停止态下按固定步长输出 PNG / OpenEXR 序列。

| 状态 | 项目 | 说明 |
|------|------|------|
| 已完成 | BRDF 重要性采样 | CPU 与 Metal kernel 均改为 GGX VNDF + cosine 半球采样 |
| 已完成 | 直接光与 MIS | 命中点会做光源采样 + shadow ray，并用 power heuristic 合并 BRDF 采样 |
| 已完成 | Principled BSDF | Schlick Fresnel、metallic F0、transmission / refraction、能量守恒都已接通 |
| 已完成 | HDR 环境照明 | `.hdr` 资源发现、环境 alias importance sampling 已完成；无环境时环境贡献归零 |
| 已完成 | 自适应采样 | CPU progressive 与 Metal RT PathTrace 都已按 8x8 tile 噪声估计分配 target samples |
| 已完成 | 降噪 | PathTrace PNG 导出已支持 albedo / normal AOV sidecar，并自动按 `OIDN(动态加载) -> MPS Guided -> CPU Guided` 选择降噪后端 |
| 已完成 | 序列输出 | Render Output 已支持固定步长驱动的 PNG / OpenEXR 帧序列导出，PathTrace EXR 走线性 beauty 输出 |

### 5.2 路径追踪目标状态

达到 **32 SPP + OIDN = 干净影视画面**：

```
光线路径:
  Camera -> Surface Hit
    |- Direct Lighting (NEE): 随机采样光源 + shadow ray
    |- BRDF Sampling: GGX IS (specular) / cosine IS (diffuse)
    |- MIS: power heuristic 组合 NEE + BRDF
    |- Russian Roulette: 概率终止低贡献路径
    +- Bounce -> next surface (递归)

材质模型:
    Principled BSDF
    |- Diffuse: Lambertian / Oren-Nayar
    |- Specular: GGX microfacet (Cook-Torrance)
    |- Fresnel: Schlick approximation
    |- Metallic: 线性插值 diffuse <-> specular
    |- Transmission: 折射 (Snell) + 全内反射
    +- Emission: 自发光面光源

后处理:
    OIDN 降噪 (albedo + normal AOV 辅助)
    -> Tonemap -> 输出 EXR/PNG
```

当前实现补充：
- Editor PathTrace PNG 导出已可输出 `beauty + albedo + normal`
- `albedo / normal` 已接到导出级降噪链路，优先使用 OIDN，缺库时自动回退到 MPS Guided / CPU Guided
- 为了缩短主渲染文件，路径追踪公共类型/降噪/图像导出已拆到 `path_trace_common.zig`、`path_trace_denoise.zig`、`image_export.zig`
- Render Output 已支持固定步长序列导出，路径会自动生成为 `{base}_{frame:04d}.png/.exr`

### 5.3 逐项实施清单

#### PT-1 GGX 重要性采样
- [x] 替换旧半球镜面采样为 GGX 可见法线分布采样 (`sampleGGXVisibleHalfVector` / `sample_ggx_visible_half_vector`)
- [x] 漫射面用 cosine-weighted 半球采样
- [x] 根据 metallic / Fresnel 概率选择 specular 或 diffuse lobe
- [x] CPU 和 Metal kernel 同步修改
- **验收**: 低 SPP 下金属反射噪声显著低于均匀半球采样

#### PT-2 NEE + MIS
- [x] 每次命中点额外采样一条 shadow ray 直连光源
- [x] 光源采样 PDF: 方向光=delta, 面光源 / 环境光=对应采样 PDF
- [x] BRDF 采样 PDF: GGX VNDF / cosine 对应值
- [x] MIS power heuristic: `w_light = pdfL^2 / (pdfL^2 + pdfB^2)`
- **验收**: 低 SPP 下直接光区域已可用，不再完全依赖间接 bounce 收敛

#### PT-3 Principled BSDF
- [x] Schlick Fresnel: `F0 + (1-F0) * (1-cosTheta)^5`
- [x] 金属: F0 = albedo; 电介质: F0 = 0.04
- [x] Transmission lobe: Snell 折射 + 全内反射判断
- [x] Roughness -> GGX alpha 映射: `alpha = roughness^2`
- [x] 能量守恒: diffuse *= (1 - metallic) * (1 - F)
- **验收**: 玻璃 / 金属材质在 CPU 与 Metal 路径追踪中都已走物理材质链路

#### PT-4 HDR 环境贴图采样
- [x] 支持 `.hdr` 天空纹理
- [x] 环境光 NEE: 根据亮度分布做 importance sampling (alias method)
- [x] 移除线性渐变 sky fallback（无 HDR 时环境贡献归零）
- **验收**: HDRI 照明下物体已有真实环境反射；无 HDR 时环境贡献为黑

#### PT-5 俄罗斯轮盘 (无偏终止)
- [x] 替换硬截止为概率终止:
  `survival_prob = min(max_component(throughput), 0.95); if (rand > survival_prob) break; throughput /= survival_prob;`
- [x] CPU 和 Metal kernel 同步
- **验收**: 间接光不再使用有偏硬截断

#### PT-6 自适应采样
- [x] CPU progressive PathTrace: 每个 tile (8x8) 追踪噪声指标
- [x] CPU progressive PathTrace: 高噪声 tile 继续采样，低噪声 tile 提前终止
- [x] CPU progressive PathTrace: 通过 per-tile target samples 分配同帧 SPP 预算
- [x] Metal RT PathTrace: 每个 8x8 threadgroup 汇总 tile 噪声指标并统一分配 target samples
- [x] CPU / GPU 验证链路已区分 path trace golden 后缀，避免 CPU PathTrace 错误复用 GPU golden
- **验收**: 视口 CPU fallback 与 Metal RT PathTrace 都已具备 tile 级自适应采样

#### PT-7 OIDN 降噪器集成
- [x] 集成 Intel Open Image Denoise (C API, 动态加载，不强绑构建机依赖)
- [x] 输出辅助 AOV: albedo buffer, normal buffer
- [x] Editor PathTrace PNG 导出：生成 `albedo / normal` sidecar，并用 AOV 做自动降噪
- [x] 32 SPP + OIDN 路径已接入；运行环境未安装 OIDN 时自动回退
- [x] Metal GPU 路径: MPS Guided denoiser (Apple Silicon 加速)
- **验收**: 导出链路已能输出 `beauty + albedo + normal`，并按 `OIDN -> MPS Guided -> CPU Guided` 自动完成一次降噪

#### PT-8 EXR 序列帧输出
- [x] 支持 OpenEXR 单帧写入
- [x] Camera Animation / 脚本 / 物理 / VFX 由固定步长 playback 驱动帧序列渲染
- [x] 输出路径自动生成 `{base}_{frame:04d}.png/.exr`
- [x] PathTrace EXR 导出补齐线性 beauty 链路
- **验收**: 10 帧动画序列可正确输出；路径追踪支持 PNG / OpenEXR 序列

---

## 六、编辑器 UX — 响应式布局与创作工作流

### 6.1 当前布局问题

| 问题 | 根因 | 位置 |
|------|------|------|
| 工具栏在窄窗口被截断 | 860px breakpoint 太高 | viewport.zig toolbar |
| 面板可拖到不可用宽度 | 无最小尺寸约束 | ImGui docking |
| 按钮文本溢出 | 硬编码宽度 (132px/304px) | toolbar buttons |
| 状态栏 1280px 处突变 | 硬编码分割比 | status bar |
| Inspector 窄时静默失败 | beginPropertyTable 返回 false 无回退 | inspector.zig |
| 图标不随面板缩放 | 固定 16px | hierarchy icons |

### 6.2 响应式布局实施清单

#### UI-1 面板最小尺寸约束
- [x] 新增 imgui bridge: `setNextWindowSizeConstraints` (C++ → Zig → gui.zig)
- [x] 所有 dock 窗口设置 `gui.setNextWindowSizeConstraints(min_w, min_h, FLT_MAX, FLT_MAX)`
  - Scene Hierarchy: min 220×120
  - Inspector: min 260×120
  - Asset Browser: min 200×100
- **验收**: ✅ 拖拽面板边不会小于最小尺寸

#### UI-2 工具栏自适应断点
- [x] Wide 断点: 860→0680, Medium: 520→0460
- [x] 模式按钮压缩: Raster 98→82, PathTrace 108→92
- [x] 右侧元素压缩: undo_source 132→100, ai_status 304→180
- **验收**: ✅ 680px 视口宽度下工具栏完整可见

#### UI-3 状态栏平滑自适应 ✅ COMPLETED
- [x] 删除 1280px 硬编码跳变
- [x] 使用比例分配: context 区 / metrics 区按窗口宽度平滑插值，并根据内容预算截断
- [x] 狭窄时隐藏低优先级指标 (内存/进程RSS)
- **验收**: ✅ 任意窗口宽度下状态栏内容可读

#### UI-4 Inspector 窄面板优雅降级 ✅ COMPLETED
- [x] panel 宽度不足时切换为 stacked 布局 (label 上 + value 下)
- [x] 属性网格按可用宽度在 table / stacked 间切换，Transform 编辑器同步降级
- **验收**: ✅ Inspector 260px 时所有属性可编辑

#### UI-5 带纹理预设物体 ✅ COMPLETED
- [x] Place Actors 面板增加: "Textured Cube"、"Textured Sphere"、"Textured Plane"
- [x] 点击后弹出纹理选择对话框选择纹理
- [x] 自动创建实体 + 材质实例 + 赋予纹理
- **验收**: 3 次点击将带纹理立方体放入场景

#### UI-6 拖拽纹理到 Inspector 材质字段 ✅ COMPLETED
- [x] Inspector 材质区域的 texture slot 支持拖拽 payload 接收
- [x] Asset Browser 中纹理条目可拖出
- [x] Material Editor 同步支持点击赋值与拖拽落槽
- **验收**: ✅ 从 Asset Browser 拖拽 .png 到 Inspector 的 Base Color 区域完成赋值

---

## 七、3D 创作工具链 — 对标 Blender 基础能力

### 7.1 对标范围

| Blender 基础环节 | Guava 当前基线 | Guava 目标能力 | 暂不做 / 延后 |
|----------------|----------------|---------------|---------------|
| 3D 视口导航 / 选择 / 变换 | ✅ 已有 | 补齐吸附、枢轴、局部/全局坐标、数值输入 | -- |
| Object Mode / Outliner / Inspector | ✅ 已有 | 对齐 Blender 的对象工作流 | -- |
| Mesh Edit Mode | ⚠️ 首版可用 | 顶点/边/面编辑 + 常用建模操作 | 高级布线、重拓扑 |
| 材质 LookDev | ✅ 参数面板已有 | 参数材质 + 节点材质两阶段 | 几何节点 |
| UV 编辑 | ❌ 缺失 | UV 查看、选择、平移缩放、基础投影 | 高级展开 / 缝线求解 |
| 相机 / 灯光 / 布光 | ⚠️ 部分已有 | 多相机、面光源、摄影灯光工作流 | IES、体积灯光编辑 |
| 动画 / 时间线 | ❌ 缺失 | 关键帧、Dope Sheet、相机序列器 | 完整 Graph Editor |
| 渲染预览 | ⚠️ 部分已有 | Solid / Material / Rendered 三档预览 | Compositor |
| 渲染输出 | ⚠️ 单帧 PNG 已有 | 图片序列 / EXR / 视频 / 4K | 专业调色与剪辑 |
| 雕刻 / 绘制 / 模拟 | 不做 | -- | 雕刻、纹理绘制、流体、布料 |
| 视频编辑 | 不做 | -- | NLE / 时间轴剪辑 |

### 7.2 创作工作流闭环

Guava 对标 Blender 的策略，不是一次性追全功能，而是先做四条真正可闭环的创作链路：

| 工作流 | 用户要完成的事 | 当前已有 | 关键缺口 | 闭环验收 |
|--------|---------------|---------|---------|---------|
| **Blockout 建模** | 从 primitive 搭场景、改体块、布置层级 | Primitive 放置 / Gizmo / Scene Hierarchy | Mesh Edit Mode、吸附、数值输入 | 10 分钟内从 Cube 搭出简单房间与门洞 |
| **LookDev** | 给模型赋材质、看预览、切换渲染模式 | Inspector 材质参数 / Path Trace / PostFX | 材质预览模式、节点材质、UV 编辑 | 一个 glTF 模型能完成贴图、粗糙度、法线调整并预览 |
| **Layout + 动画** | 相机飞行、物体关键帧、镜头切换 | Camera 实体 / Timeline 面板基础壳子 | 关键帧系统、Dope Sheet、Sequencer | 做出 5 秒镜头并可逐帧预览 |
| **Final Render** | 导出海报图或短视频 | PNG 单帧输出 / PT 采样控制 | EXR、帧序列、视频编码、进度反馈 | 一键导出 4K PNG / EXR / MP4 |

### 7.3 实施原则

1. **先闭环，再追功能面**：优先补齐“建模 -> 材质 -> 动画 -> 输出”最短链路，避免只堆零散面板。
2. **一份数据，多种视图**：Object Mode、Edit Mode、UV Editor、Timeline 共享同一份场景/资源数据，不复制编辑状态。
3. **实时与离线共用材质语义**：材质编辑输出统一 AST/参数层，再分别喂给光栅与路径追踪，不让 UI 直接拼 shader 字符串。
4. **编辑器工作流优先于 DCC 全覆盖**：优先支持游戏/影视预演常用能力，复杂 DCC 功能保持延后。
5. **每项工具都有可录像的验收脚本**：每个 CT 条目都必须能被稳定复现和演示，而不是停留在“面板存在”。

### 7.4 创作工具实施清单

#### CT-1 Mesh Edit Mode（基础建模）
- [x] Mode 切换: Object / Edit
- [x] 元素选择: 顶点 / 边 / 面
- [x] 基础操作（首版）: Extrude / Delete
- [x] 基础操作: Inset / Bevel / Loop Cut / Merge
- [x] 常用辅助: Duplicate / Separate / Recalculate Normal / Pivot to Selection
- [x] Undo/Redo 与 Inspector / Hierarchy 基础同步（网格变更后会触发快照、层级刷新与可渲染更新）
- **当前状态**: 单对象 Mesh Edit Mode 已形成可用闭环，支持从 Cube 直接完成白模级门窗开洞流程
- **验收**: ✅ 从一个 Cube 编辑出带门洞和窗洞的简单房间白模

**端到端操作路径校验（Cube -> 房间白模）**
1. 选中 Cube，按 `Tab` 进入 Edit Mode。
2. 按 `3` 进入面模式，选中正面墙体区域，按 `I` 内插出门窗边框面。
3. 选中内插后的门窗面，按 `E` 轻微向内挤出，再按 `Delete` 删除内层面形成开洞。
4. 选中洞口边环，按 `B` 倒角补出缓冲边；必要时按 `Ctrl+R` 在墙体上加环切辅助线。
5. 需要分件时，选中目标面按 `P` 分离，独立成新实体继续编辑。
6. 形体整理阶段使用：`Shift+D` 复制、`M` 合并点、`Shift+N` 重算法线、`.` 轴心到选中。

**本轮稳健性修补（2026-04）**
- Bevel（`B`）: 在保留“单边分裂 + 倒角带补面”的基础上，新增“多边连续倒角”过渡策略：同一三角面命中多条选中边时使用局部稳定扇形重建，减少相邻边共面过渡处的裂缝与翻面。
- Loop Cut（`Ctrl+R`）: 边链扩展加入方向连续性、流形优先和支路惩罚打分，并在同分情况下使用确定性 key 规则，提升复杂支路下选择稳定性。
- Inset（`I`）: 改为区域一致内插（共享 inset 顶点 + 仅边界侧壁），避免相邻选中面出现内部重叠侧壁与裂缝。
- Extrude（`E`）: 挤出距离改为按选中区域平均边长自适应，避免小面过冲或大面位移不足。
- 几何提交前增加网格有效性校验（索引越界、三角倍数、NaN/Inf 顶点）以避免坏网格写回。

**交互模式增强（Blender 对齐方向）**
- `E / I / B` 进入交互调整模式：鼠标移动实时改变参数并预览结果。
- 左键确认本次操作并写入历史；右键或 `Esc` 取消并回滚到操作前网格。
- 交互模式期间暂停元素点击选择，避免参数拖动和选择行为互相干扰。

#### CT-2 变换约束 / 吸附 / 数值输入
- [x] 坐标空间: World / Local
- [x] 枢轴模式（首版）: Origin / Bounds Center / Median Point / Active Element / 3D Cursor / Individual Origins
- [x] 3D Cursor: viewport 可视化 + 点击放置 + 工具栏入口 / 快捷键
- [x] 吸附: Grid / Vertex / Surface
- [x] Surface Snap: Align Rotation to Surface Normal
- [x] Individual Origins: 多选旋转 / 缩放按各自局部空间约束
- [x] 键盘约束: `G/R/S` 后接 `X/Y/Z`
- [x] 数值输入: 位置 / 旋转 / 缩放支持直接输入
- **验收**: 将多个物体按网格和顶点吸附精确拼装，不依赖肉眼微调

#### CT-3 材质编辑器（两阶段）

**Phase 1: 参数材质增强**
- [ ] 统一 Principled 参数面板: BaseColor / Metallic / Roughness / Normal / Emissive / Alpha
- [ ] 预览球体、预览平面、贴图 checker
- [ ] 材质实例与共享母材质

**Phase 2: 节点式材质编辑器**
- [ ] 节点系统: PBR 参数节点 -> 输出节点
- [ ] 内置节点: Texture Sample, Color, Float, Mix, Normal Map, Noise, Voronoi
- [ ] 编译为光栅 Uber Shader 参数图 + Path Tracer BSDF 闭包
- **验收**: 用节点编辑器创建噪声混合材质，光栅与路径追踪观感一致

> **⚠️ 技术警告**: 跨越两种截然不同的渲染范式（光栅 vs 路径追踪）共享一套参数图极其困难。
> 
> **设计约束**: 必须设计严谨的 Material AST（一阶逻辑），提取 BaseColor / Normal / Roughness / Metallic 等纯物理属性，**一份定义，多端生成**：
> ```
> Material UI → Material AST → ┬→ GLSL Uber Shader (raster)
>                             └→ BSDF Closure (path tracer)
> ```
> 如果材质系统（Shader Codegen）不能同时生成光栅化 Shader 和光追需要的 Closest Hit Shader，就会出现"两个渲染器渲染结果完全不同"的灾难性问题。

#### CT-4 关键帧动画系统 + Dope Sheet
- [ ] 属性关键帧: 任意 float / vec3 属性可设置关键帧（Transform、Light Intensity、Camera FOV 等）
- [ ] 插值类型: Linear / Bezier / Step
- [ ] Timeline UI: 菱形关键帧标记、拖动、框选
- [ ] 播放控制: Play / Pause / 帧步进 / 跳转
- [ ] Dope Sheet 首版: 按对象和属性分组列出关键帧
- **验收**: 创建 5 秒相机飞行动画并可逐帧检查轨迹

#### CT-5 Camera Sequencer（镜头轨）
- [ ] 多相机: 场景中放置多个 Camera 实体
- [ ] Shot Track: 时间线上分段标记使用哪个 Camera
- [ ] 镜头参数: Cut / Hold；Blend 留待后续
- [ ] 渲染输出: 按 Sequencer 相机顺序导出帧序列
- **验收**: 两个相机在 3 秒处切换，导出结果与时间线一致

#### CT-6 面光源（Area Light）
- [ ] 新光源类型: Rectangle / Disk
- [ ] 编辑器表现: 尺寸、方向、颜色、强度、温度
- [ ] 光栅: 近似面光 + soft shadow
- [ ] 路径追踪: 真正面光源采样（NEE）
- **验收**: 路径追踪下获得物理正确软阴影，Raster 预览方向和范围一致

#### CT-7 基础 UV 编辑器
- [ ] 独立 2D UV 视图面板
- [ ] 显示当前选中 mesh 的 UV 展开
- [ ] 支持选择 UV 顶点 / 边 / 面，基础平移 / 旋转 / 缩放
- [ ] 自动 UV 投影: Box / Planar / Cylindrical
- [ ] Checker 预览与 texel density 粗略反馈
- **验收**: 查看 glTF 导入模型 UV，调整后纹理映射正确更新

#### CT-8 渲染视图 / LookDev 预览
- [ ] 视口着色模式: Solid / Material / Rendered
- [ ] Matcap / Checker / HDRI 预览开关
- [ ] 选中物体隔离预览与材质球预览同步
- [ ] Path Trace 预览可降采样 / 限时迭代，避免编辑器卡死
- **验收**: 同一模型可在三种视图间秒切，材质判断一致

#### CT-9 渲染输出面板
- [x] 首版离线单帧输出: 分辨率预设（Viewport / 1080p / 2K / 4K）+ 自定义分辨率 / PNG 输出路径 / `Render Image`
- [x] 采样设置（首版）: PathTrace 导出 SPP / Bounces，导出时自动切换到全分辨率 tracing
- [ ] 输出设置: 帧范围 / 输出格式 EXR / PNG Sequence
- [ ] 采样设置: 降噪开关 / 自适应采样
- [ ] 一键渲染: `Render Animation`
- [ ] 进度显示: 当前帧 / 总帧 + 累积 SPP + 预计剩余时间
- [ ] 4K 支持: 3840x2160 渲染，分 tile 避免显存溢出（每 tile 512x512）
- **验收**: 可设置 3840x2160 输出 EXR 序列，并稳定完成 10 帧动画导出

#### CT-10 视频编码输出（FFmpeg）

引擎不做视频编辑器，但必须能将渲染帧序列编码为标准视频格式。策略：渲染器输出帧序列 -> FFmpeg 子进程编码 -> 输出 MP4/MOV。

- [ ] FFmpeg 子进程调用封装（不链接 libav，仅调用 ffmpeg CLI）
- [ ] 支持编码格式: H.264 / H.265 / ProRes
- [ ] 渲染流水线: Path Tracer 渲染帧 -> EXR 暂存 -> OIDN 降噪 -> Tonemap -> FFmpeg 编码
- [ ] 音频混合: 场景 AudioSource 混音轨道合并到视频（SoLoud -> WAV -> FFmpeg mux）
- [ ] 输出预设:
  - **Web**: 1080p H.264 CRF18, 30fps
  - **4K Cinema**: 3840x2160 H.265 CRF15, 24fps
  - **Post-Production**: 4K ProRes 422, 24fps（供 DaVinci/Premiere 后期）
- [ ] 编辑器 UI: 渲染输出面板增加 `输出格式` 下拉 + 编码质量滑块
- **验收**: 10 秒相机动画 -> 一键渲染 -> 输出 4K H.265 MP4，可在播放器中流畅播放

### 7.5 优先级与落地顺序

| 优先级 | 目标 | 对应条目 | 说明 |
|--------|------|---------|------|
| **P0** | 建立 Blender 式基础创作闭环 | CT-1 / CT-2 / CT-4 / CT-5 / CT-8 / CT-9 | 先让用户能建模、打镜头、预览、导出 |
| **P1** | 补齐 LookDev 与布光 | CT-3 / CT-6 / CT-7 | 材质、面光源、UV 构成第二层闭环 |
| **P2** | 交付影视向输出 | CT-10 + PT-8 | 视频编码、序列输出、降噪整合 |

> 判断标准：如果某能力无法直接缩短“从空场景到 5 秒镜头 + 4K 导出”的路径，就不进入 P0。

---

## 八、游戏运行时系统

### 8.1 逐项清单

#### GR-1 音频系统修复与完善
- [x] 修复 SoLoud 初始化错误报告：`soloud_bindings.init()` 记录错误码 + SoLoud 内部错误描述
- [x] `application.zig` 改善日志：失败时明确说明引擎仍可无音频运行
- [ ] AudioSource / AudioListener / AudioClip 组件
- [ ] 3D 空间音效: 距离衰减、Voice group
- [ ] Inspector 编辑: 音量 / 循环 / 3D 设置
- **验收**: ✅ 错误诊断可用；组件系统待后续阶段实现

#### GR-2 多场景管理
- [ ] SceneManager: `loadScene("level_2")` / `unloadScene()`
- [ ] 异步加载 + 加载界面回调
- [ ] 全局不销毁对象标记 (`DontDestroyOnLoad`)
- **验收**: 从主菜单场景加载游戏场景，玩家数据跨场景保留

#### GR-3 GameState 状态机
- [ ] 状态: Editor / Playing / Paused / Stopped
- [ ] Play 时克隆场景，Stop 时恢复 (与 Unity Play Mode 一致)
- [ ] Time.deltaTime / Time.timeScale
- **验收**: 按 Play, 物理运行, 按 Stop, 场景恢复到 Play 前状态

#### GR-4 Physics 脚本宿主 API
- [ ] Raycast: `physics.raycast(origin, direction, maxDist) -> HitInfo`
- [ ] OverlapSphere / OverlapAABB
- [ ] TriggerEnter / TriggerExit 回调到脚本层
- **验收**: 脚本发射射线检测碰撞，返回碰撞实体 ID

#### GR-5 导航寻路
- [ ] 集成 Recast/Detour
- [ ] NavMesh 从场景 static mesh 烘焙
- [ ] Agent 组件: 自动寻路 + 避障
- [ ] 编辑器可视化 NavMesh 覆盖层
- **验收**: AI Agent 自动绕过障碍物到达目标点

#### GR-6 输入映射系统
- [ ] Action -> Key/Gamepad 映射表 (JSON 配置)
- [ ] `input.isActionPressed("jump")` / `input.getAxis("move_x")`
- [ ] Editor 中可视化映射编辑
- **验收**: 空格键和手柄 A 键都触发 "jump" action

#### GR-7 游戏内 UI 系统
- [ ] Canvas 组件: 分辨率自适应
- [ ] 控件: Button / Text / Image / ProgressBar / 九宫格
- [ ] UI 事件系统: 射线 vs UI 碰撞
- [ ] 脚本宿主绑定: `ui.createButton("Start")` / `ui.setText(id, "HP: 100")`
- **验收**: 屏幕上方显示血条，血量变化时进度条更新

#### GR-8 C# Script VM + WASM VM 分层

不再把 `WASM VM` 设计成承接 Python / MicroPython / .NET NativeAOT / Mono 等多层语言工具链；这里改为更清晰的职责分离：

```text
                Game Engine

           ┌───────────────────┐
           │      Zig Core     │
           │ Rendering Physics │
           └─────────┬─────────┘
                     │
        ┌────────────┴─────────────┐
        │                          │
   C# Script VM               WASM VM
 (gameplay logic)           (plugins)
        │                          │
   NPC logic                 Mods
   UI logic                  AI scripts
   Gameplay                  Tools
```

设计约束：
- `Zig Core` 负责渲染、物理、资源系统和宿主 API。
- `C# Script VM` 只负责 gameplay logic，包括 `NPC logic`、`UI logic`、`Gameplay`。
- `WASM VM` 只负责 plugins，包括 `Mods`、`AI scripts`、`Tools`。
- 不再把 `WASM VM` 作为通用多语言脚本前端承载层，避免工具链膨胀。

实施清单:
- [x] 接入 `C# Script VM`，优先覆盖 NPC / UI / Gameplay 生命周期
- [x] 保持 `WASM VM` 轻量化，只暴露插件所需的宿主 API
- [ ] 编辑器中明确区分 `Scripts` 与 `Plugins` 的加载、热重载与调试入口
- [x] 统一宿主桥接层，由 `Zig Core` 同时服务 `C# Script VM` 和 `WASM VM`
- [ ] 完善脚本工具链，支持一键跳转到 VS Code、Rider 等 IDE 编写 C# 脚本或 WASM 插件
- **验收**: `C# Script VM` 驱动 NPC / UI / Gameplay；`WASM VM` 独立加载 Mods / AI scripts / Tools，二者职责清晰且工具链不互相耦合

当前实现:
- `C# Script VM` 走 `.NET NativeAOT`，运行时支持直接加载 `.dll/.so/.dylib`，也支持把 `source_path` 指向 `.csproj` 后自动执行 `dotnet publish` 并回填 `artifact_path`。
- C# NativeAOT 宿主桥目前覆盖 `log`、实体查找、`Transform` 读写、输入、时间缩放、游戏状态等 gameplay 所需 API。
- `ScriptRuntime` 会为 `.csproj` 注册热重载监听，覆盖项目文件和项目目录下的 `*.cs`，并在变更后重新发布 NativeAOT 共享库。
- `WASM VM` 按 `plugin` / `editor_utility` host profile 区分能力，普通插件不会默认拿到编辑器 UI / selection API。

当前验证:
- `zig build test-script-vm`
- `zig build test-csharp-nativeaot`
- NativeAOT 测试样例位于 `examples/csharp/nativeaot_mover`，验证路径为 `.csproj -> dotnet publish -> 共享库加载 -> Entity Transform 更新`

使用约束:
- 推荐把 gameplay C# 脚本组织成 `.csproj`，让运行时自动发布 NativeAOT；若已经有预编译产物，也可以直接把 `source_path` 或 `artifact_path` 指向共享库。
- `GUAVA_DOTNET` 可用于显式指定 `dotnet` 可执行文件；否则运行时会依次尝试 `DOTNET_ROOT*`、`PATH` 和常见安装目录。

> **⚠️ 设计陷阱**: C# NativeAOT 编译后是静态的，**天然不支持热重载**。如果开发阶段频繁改代码并立刻看效果，每次都需要重新编译整个 `.dll` 并重新注入，体验极差。
>
> **解决方案**: 建议在开发阶段使用 Mono JIT 模式提供热重载能力（游戏运行时自动检测源文件变更并重新加载），而在发布（Shipping）阶段切换到 NativeAOT 追求极致性能。

---

## 九、AI-Native 基础设施

### 9.1 已完成

| 能力 | 状态 |
|------|------|
| MCP stdio 协议 | ✅ |
| 只读场景/实体/选择感知 | ✅ |
| CommandQueue 统一写入 | ✅ |
| Staged Transaction + Ghost Preview | ✅ |
| Query API (文本/组件/空间/BVH) | ✅ |
| Schema 资源族 | ✅ |
| WASM VM (插件) + Inspector 反射 | ✅ |
| Editor Utility UI (21 host_ui API) | ✅ |

### 9.2 待建

#### AI-1 Command 扩展
- [ ] 覆盖材质参数、渲染设置、动画状态
- [ ] Command 增加 `source: enum { human, ai }` 标记
- [ ] 可视化 Command Timeline UI

#### AI-2 MCP 三层 API
- [ ] Scene API: `create_entity`, `set_component`, `delete_entity`
- [ ] Asset API: `import_texture`, `compile_shader`, `bake_navmesh`
- [ ] Render API: `screenshot`, `switch_mode`, `render_sequence`

#### AI-3 截图反馈回路
- [ ] Command 完成后的稳态帧自动截图
- [ ] 512x512 base64 编码回传
- [ ] 支持修改前/后对比

#### AI-4 Ghost Highlight
- [ ] 复用 outline_pass 增加 AI 紫色通道
- [ ] AI 操作的物体呼吸灯脉冲


目前 `runMcp`（外部控制）与 `runEngine`（内部编辑器含 `ai_chat`）处于割裂状态。`ai_chat` 拥有不安全的直写特权，且未复用 MCP 的工具链；MCP 服务强制绑定 `stdio`，导致无法在常规编辑器启动时后台常驻，且每帧全局快照严重拖拽光栅化管线性能。

### 9.3 终极进化目标：In-Memory MCP 双轨架构
将引擎重构为**内嵌式 AI 服务总线**，使 MCP 成为全引擎唯一的 AI 交互标准接口。无论是外部 Claude Desktop 还是内置 `ai_chat` 面板，均作为 Client 接入同一个 In-Memory MCP Server。

**核心改造路线图：**

#### AI-1：下沉基础组件与 I/O 抽象
- [ ] 将 `ToolBridge`、`SnapshotStore` 从 `runMcp` 解耦，下沉至引擎核心，使 `runEngine` 默认初始化。
- [ ] 抽象 `Server.handleMessage` 的输出流：支持 `std.fs.File.writer()` (外部 stdio) 和 `std.ArrayList(u8).writer()` (内部内存回调)。

#### AI-2：状态同步懒加载 (Lazy Sync)
- [ ] 移除 `SyncLayer` 中每帧强制执行的 `world.updateHierarchy()` 和 `replaceFromRenderer()`。
- [ ] 引入按需快照机制：仅在 `ai_chat` 提交请求前，或场景发生实质性变更（Dirty Flag）且后台存在活跃 MCP 客户端时，才触发一次快照。

#### AI-3：内部 UI 接入 MCP
- [ ] `ai_chat` 面板剥离特权操作代码，全面改用 In-Memory MCP 协议。
- [ ] 引入异步 Job System：`ai_chat` 的网络请求与 MCP JSON 解析必须放入后台 Job，防止阻塞 ImGui 渲染主线程。
- [ ] 特权上下文注入：`ai_chat` 在发起 LLM 请求前，直接读取内存中的 `selection://current` 等资源作为隐式 Prompt。

#### AI-4：网络化扩展 (可选)
- [ ] 实现 SSE (Server-Sent Events) 或 WebSocket 传输层，彻底摆脱 `stdio` 独占问题，允许编辑器在正常打印 log 的同时，后台静默伺服外部网络 AI Agent 请求。
---

## 十、分阶段执行路线图

> **架构原则：先打地基，再精装修。** 所有依赖 Compute Shader 的现代特效（TAA、SSGI、
> 多光源剔除）必须在具备 Compute Queue / 显式 Barrier 的后端上实施，避免在缺少这些能力的管线上重复造轮子。

### Phase 1：修复基础 — 让看得见的东西先正确

> 前置: 无

| ID | 任务 | 检验标准 | 状态 |
|----|------|---------|------|
| R-1 | 审计纹理绑定 + 修复 GPA 泄漏 | render-test 套件存在，golden 需维护 | ✅ |
| R-2 | SSAO 合成到 HDR 缓冲 | 角落变暗有接地感 | ✅ |
| UI-1 | 面板最小尺寸约束 | 拖窄不再失效 | ✅ |
| UI-2 | 工具栏断点下调至 680px | 680px 宽仍可用 | ✅ |
| GR-1 | 音频错误诊断 | SoLoud 错误码+描述 | ✅ |

### Phase 2：光栅管线增强（纯 Fragment 可完成） ✅ COMPLETED

> 前置: Phase 1
> 限定范围: 仅含不依赖 Compute Shader 的光栅改进。

| ID | 任务 | 检验标准 | 状态 |
|----|------|---------|------|
| R-3 | 级联阴影 (4-CSM) | 远处阴影清晰 | ✅ |
| R-4 | 多光源 (dir x4 + point x16) | 4 盏点光照亮不同区域 | ✅ |
| R-8 | Contact Shadows | 物体底部有接触阴影 | ✅ |

### Phase 3：RHI 重构 — Metal / Vulkan 原生 Backend + Compute

> 前置: Phase 2（光栅管线基本功能稳定后换底层）
>
> 这一阶段已经在当前代码里落地为自研 RHI：Metal 主路径可用，Vulkan / DX12 仍以目标态描述，
> SDL3 只负责窗口与输入，Compute / RT 路径为部分接通并带回退。

| ID | 任务 | 检验标准 |
|----|------|---------|
| RHI-1 | Metal Graphics Backend | 18 个 Pass 在新 RHI 上渲染一致 |
| RHI-2 | Metal Compute Backend | BRDF LUT 已有 GPU 路径，SSAO dispatch 部分接通 |
| RHI-3 | Metal RT 统一到 RHI | RT Shadow 和 Path Trace 走统一接口；其他平台仍待补齐 |

### Phase 4：Compute 加持的现代光栅特效 ⚠️ IN PROGRESS

> 前置: Phase 3（RHI-2 Compute 已就绪）
>
> 当前代码已把 TAA / SSAO / SSGI 接入主渲染链，Contact Shadows 本轮也已改成正式 pass + HDR composite。
> SSAO 已统一为 compute 路径，TAA 现已补齐正式 velocity buffer；SSR 也已正式接回 HDR 主链，但 roughness blur 仍待继续实现。

| ID | 任务 | 检验标准 | 状态 |
|----|------|---------|------|
| R-5 | TAA (Compute temporal resolve) | 围栏边缘无闪烁 | ✅ |
| R-6 | SSGI (Compute downsample + denoise) | 红墙旁白物体有红色溢出 | ✅ |
| R-7 | SSR 粗糙度模糊 | 粗糙表面模糊反射 | ⚠️ |
| R-9 | 渲染风格插件化系统 | 用户可导入自定义风格插件 | ⬜ |
| R-10 | 通用插件系统基础设施 | PluginRegistry / 生命周期 / 依赖管理 | ⬜ |
| R-11 | 渲染风格作为首个插件用例 | 注册内置PBR / 用户插件加载 / Editor UI | ⬜ |

### Phase 5：路径追踪器重写

> 前置: RHI-2 (Compute)

> 当前状态：PT-1 / PT-2 / PT-3 / PT-4 / PT-5 / PT-6 / PT-7 已完成；PT-8 仍待收尾。

| ID | 任务 | 检验标准 |
|----|------|---------|
| PT-1 | GGX 重要性采样 | 4 SPP 金属球可辨认 |
| PT-2 | NEE + MIS | 直接光 4 SPP 基本收敛 |
| PT-3 | Principled BSDF | 玻璃球折射正确 |
| PT-4 | HDR 环境贴图 | HDRI 照明下物体有环境反射 |
| PT-5 | 俄罗斯轮盘 | 间接光亮度不再偏暗 |
| PT-7 | OIDN 降噪 | 32 SPP + 降噪 = 干净画面 |

### Phase 6：创作工具链

> 前置: Phase 2 (多光源), Phase 5 (PT)

| ID | 任务 | 检验标准 |
|----|------|---------|
| CT-1 | Mesh Edit Mode | 从 Cube 建出简单房间白模 |
| CT-2 | 吸附 / 约束 / 数值输入 | 物体可精确拼装 |
| CT-4 | 关键帧动画 + Dope Sheet | 5 秒相机飞行动画 |
| CT-5 | Camera Sequencer | 多相机切换渲染 |
| CT-8 | 渲染视图 / LookDev | Solid / Material / Rendered 秒切 |
| CT-9 | 渲染输出面板 (含 4K) | 一键渲染 4K EXR |
| CT-10 | FFmpeg 视频编码 | 4K H.265 MP4 输出 |
| PT-8 | EXR 序列帧输出 | 10 帧动画序列正确输出 |

### Phase 7：游戏运行时补全

> 可与 Phase 6 并行

| ID | 任务 | 检验标准 |
|----|------|---------|
| GR-2 | 多场景管理 | 跨场景保留玩家数据 |
| GR-3 | GameState (Play/Stop) | Stop 后场景恢复 |
| GR-4 | Physics 脚本宿主 API | 脚本中 raycast 工作 |
| GR-5 | 导航寻路 | Agent 自动避障 |
| GR-6 | 输入映射 | 键盘+手柄映射同一 action |
| GR-7 | 游戏内 UI | 血条随数值变化 |
| GR-8 | C# Script VM + WASM VM 分层 | Gameplay 脚本与插件职责清晰 |

### Phase 8：跨平台 + 创作工具扩展

> 前置: Phase 3

| ID | 任务 | 检验标准 |
|----|------|---------|
| RHI-4 | DX12 Backend | Windows 平台完成后端补齐（目标态） |
| CT-3 | 材质编辑器 | 噪声混合材质参数可编辑 |
| CT-6 | 面光源 | PT 与 Raster 预览方向一致 |
| CT-7 | UV 编辑器 | 查看/调整 UV 映射 |
| PT-6 | 自适应采样 | 渲染时间减半 |

### 技术深水区预警

以下三项在纸面上清晰，实际编码时复杂度指数级膨胀，需提前设计。

#### ⚠️ 1. 材质编辑的双向编译 (CT-3)

计划中提到"编译为 GLSL fragment shader（光栅）+ path tracer eval 函数（离线）"。
跨越两种截然不同的渲染范式共享一套参数图极其困难。

**破局策略：** 不要尝试从编辑器 UI 直接生成目标代码字符串。必须设计严谨的内部中间层
（Material AST），提取 BaseColor / Normal / Roughness / Metallic 等纯物理属性，
然后分别喂给光栅化管线的 Uber Shader 和路径追踪的 Material 闭包。

```
Material UI → Material AST → ┬→ GLSL Uber Shader (raster)
                            └→ BSDF Closure (path tracer)
```

#### ⚠️ 2. Render Graph 瞬态内存复用 (Transient Memory Aliasing)

Section 3.5.1 中此项标记为 ❌ 缺失。当管线膨胀到 15+ Pass（Bloom 降采样链、
SSAO 模糊、TAA 历史等），1440p 分辨率下不做瞬态显存复用，VRAM 占用轻松突破
2 GB，Mac 统一内存带宽吃紧。

**破局策略：** 利用已有的 `ResourceLifetime`（first\_use / last\_use），在 RHI 重构
（Phase 3）完成后立刻接入内存池算法——基于时间的堆栈分配，让无生命周期交集的
Render Target 物理复用同一块显存。

#### ⚠️ 3. Jolt Physics 固定步长与变帧率撕裂 (GR-3)

Jolt Physics 极度依赖固定步长（Fixed Timestep）。在实现 GameState 时，必须严格
分离渲染帧（可变 delta + 插值）和物理逻辑帧（固定频率 60 Hz），否则 AI 寻路和
物理碰撞会产生不可复现的幽灵 Bug。

```
game_loop:
  accumulator += delta_time
  while accumulator >= FIXED_DT:
      physics.step(FIXED_DT)
      accumulator -= FIXED_DT
```

#### ⚠️ 4. Zig + C# 内存所有权边界

Zig 是手动管理内存，C# 是带 GC（垃圾回收）的。当 C# 脚本持有一个 Zig 层实体的引用时，如果 Zig 层删除了该实体，C# 层的引用会变成**野指针**，导致崩溃。

**破局策略**：在中间层实现基于 Entity ID（Handle）的访问机制，**永远不要让脚本层直接持有指向 Zig 结构体的指针**。

```zig
// ❌ 错误：直接暴露指针
pub fn getEntityTransform(entity: EntityId) *Transform

// ✅ 正确：通过 Handle 访问，Zig 层可安全删除
pub fn getEntityTransform(entity: EntityId) Transform  // 复制一份
pub fn getEntityTransformRef(entity: EntityId) *Transform  // 仅在确认 entity 存活时返回
```

---

## 十、分阶段执行路线图
  alpha = accumulator / FIXED_DT
  render(lerp(prev_state, curr_state, alpha))
```

---

## 十一、开发纪律

### 11.1 日常流程
1. 改最小模块 -> 跑 `zig build` -> 跑 `zig build render-test -- --suite --frames 3` -> 跑 `zig build run -- --frames 120`
2. 不要同时大面积改 RHI 和渲染 Pass — 问题来源不可分辨
3. RHI 重构期间保持 SDL3 Backend 可切换回退

### 11.2 验收方式
- 编译验证 + render-test 套件 (8 配置 golden 对比) + 手工 smoke test
- 每个新渲染特性必须在 render-test 套件中有对应配置
- Golden image 更新需附说明

### 11.3 着色器开发
- 源码: `assets/shaders/*.glsl`
- 编译: `zig build shaders` -> SPIR-V + MSL (manifest.json)
- 新 Pass: 必须在 render_graph.zig 注册依赖关系

### 11.4 RHI 切换检查清单
切换到新 RHI Backend 前，逐项验证:
- [ ] 所有 18 个 Pass 渲染正确
- [ ] render-test 8 配置 golden 对比通过
- [ ] GPU 内存不泄漏 (运行 120 帧后 RSS 稳定)
- [ ] 帧率不回退 (60 FPS baseline scene)

### 11.5 线程安全
- MCP 协议线程不直接写 `World`，只读快照
- 渲染线程不写 ECS，只读 PreparedScene
- 退出信号用原子变量

---

## 十二、术语表

| 术语 | 含义 |
|------|------|
| RHI | Rendering Hardware Interface — 渲染硬件接口抽象层 |
| CSM | Cascaded Shadow Maps — 级联阴影贴图 |
| SSAO | Screen Space Ambient Occlusion — 屏幕空间环境遮蔽 |
| SSGI | Screen Space Global Illumination — 屏幕空间全局照明 |
| SSR | Screen Space Reflections — 屏幕空间反射 |
| TAA | Temporal Anti-Aliasing — 时间抗锯齿 |
| NEE | Next Event Estimation — 下一事件估计（直接光源采样） |
| MIS | Multiple Importance Sampling — 多重重要性采样 |
| GGX | 微面元分布模型（Trowbridge-Reitz） |
| BSDF | Bidirectional Scattering Distribution Function — 双向散射分布函数 |
| OIDN | Intel Open Image Denoise — 开源 AI 降噪器 |
| SPP | Samples Per Pixel — 每像素采样数 |
| AOV | Arbitrary Output Variable — 辅助渲染通道 (albedo/normal/depth) |
| EXR | OpenEXR — HDR 图像格式 |
| `World` | 引擎主场景世界，ECS 容器 |
| `CommandQueue` | AI 与编辑器共享的统一写入口 |
| MCP | Model Context Protocol — AI 读写场景的协议 |
| Staged Transaction | 待确认的 AI 修改（需 apply/discard） |
| `PreviewWorld` | Staged 对应的预览世界 |
| `ScriptVM` | 文档中的泛称；当前已拆分为 `C# Script VM`（gameplay / NativeAOT）与 `WASM VM`（plugins） |
| Principled BSDF | 统一材质模型（对标 Blender / Disney） |
| RenderGraph | 渲染图 - 当前主要用于声明式 Pass 依赖与统计；执行仍以 `renderer.drawFrame()` 手工调度为主 |
| StylePlugin | `render_style` 类型化渲染扩展；运行时由 `StyleRegistry` / `Renderer` 持有 |
| PluginRegistry | 插件注册表 - 管理插件元数据、来源、查询、生命周期；不直接拥有 GPU / VM 运行时对象 |
| PluginLifecycle | 插件生命周期状态 (`unloaded` / `loaded` / `enabled` / `load_error`) |
| PluginCapability | 插件能力枚举 (shader / compute_pass / render_pass / audio_processor) |
