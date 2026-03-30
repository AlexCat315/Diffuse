# Guava Engine — Hybrid Renderer 升级路线

> **主题**: 从当前前向光栅主管线演进到 Clustered Forward+，并为未来 Hybrid Renderer 打基础
> **上次更新**: 2026-03-30

---

## 1. 结论先行

Guava Engine 当前最务实、性价比最高的实时渲染升级路线不是立刻切到纯 Deferred，而是：

1. 先把光源数据从大块 fragment uniform 数组迁到 GPU buffer
2. 再补齐 `Compute + Light Culling + Clustered` 基建
3. 然后把当前主光栅管线升级为 `Forward+ / Clustered Forward`
4. 最后再视性能目标决定是否为不透明物体增加 `Visibility Buffer` 或 `G-Buffer`

这条路线的核心价值是：

- 立刻解除当前 `point light / spot light` 的硬编码上限
- 最大化复用现有 `Base Pass + Skybox + Transparent + Post FX` 体系
- 不破坏透明物体、MSAA、编辑器预览、RT Shadow、PathTrace 现有工作流
- 为未来 Hybrid Renderer 留出平滑演进空间

---

## 2. 当前代码基线

截至 2026-03-30，Guava 的实时光栅主管线本质上是一个带 Depth Prepass 的前向渲染器：

- 主光照发生在 `mesh.frag.glsl` 中，材质采样、PBR、CSM、IBL、点光、聚光都在同一个 fragment shader 内完成
- `BasePass.draw` 直接把着色结果写入 HDR 颜色目标
- 透明物体继续复用同一套前向材质路径
- SSAO、SSGI 等屏幕空间效果已经走 Compute Pass
- Path Trace 已作为独立 `pipeline_mode` 存在，不与光栅主管线混在一起

当前对未来升级最关键的现实约束如下：

### 2.1 已经具备的能力

- 自研 RHI 已支持 `ComputePipeline`
- 已支持 `beginComputePass / dispatchCompute`
- 已支持 `storage texture` 与 `storage buffer` 绑定
- SSAO / SSGI 已有现成 Compute Pass 代码路径可参考

### 2.2 当前主管线的瓶颈

- `mesh_pass.zig` 中 `max_point_lights = 16`、`max_spot_lights = 16`
- `BasePassUniforms` 仍将点光/聚光按固定上限塞进 fragment uniform
- `mesh.frag.glsl` 逐像素遍历 uniform 中的全部 point/spot light
- 当前 RenderGraph 更像“声明式统计和依赖草图”，实际帧执行仍以 `renderer.drawFrame()` 手工调度为主
- 当前 RenderGraph 的资源语义以纹理为主，还没有把“GPU buffer 资源生命周期”纳入一等公民

结论是：

现在最该优先解决的问题不是“要不要 Deferred”，而是“如何把实时光照从固定上限 uniform 方案升级到 GPU 可扩展的数据驱动方案”。

---

## 3. 为什么不建议第一步直接上 Deferred

纯 Deferred 并不是 Guava 当前阶段最优的第一步，原因有四个：

### 3.1 当前收益不如 Forward+ 直接

Guava 现在最明显的问题是光源数量上限，而不是 G-Buffer 缺失。
只要把光源数据改为 GPU buffer，再加上 Clustered Light Culling，就已经能把主矛盾解决掉。

### 3.2 透明路径本来就更适合保留前向

即使将来增加 Deferred 或 Visibility Buffer：

- 透明物体
- 粒子
- Gizmo / Overlay
- 一部分特殊材质

依然大概率要继续走前向路径。

换句话说，`Forward+` 并不是过渡方案，而是未来 Hybrid 架构中的长期组成部分。

### 3.3 Deferred 会带来更大的第一阶段改造面

如果一上来做 Deferred，需要同时处理：

- G-Buffer 格式设计
- MRT 输出与带宽成本
- Lighting Pass
- 不透明/透明分流
- 材质路径重构
- 后处理输入切换

这会把首轮改造的风险和回归面迅速放大。

### 3.4 Guava 现有代码更适合渐进升级

当前代码的主通道组织已经比较清晰：

- `depth_prepass`
- `base_pass`
- `skybox`
- `transparent`
- `post process`

在这条链路里插入“Light Culling Pass + Forward+ 取灯”是自然延伸，而不是推翻重来。

---

## 4. 目标架构

Guava 的中期目标应当是一个 `Hybrid Renderer`：

- 不透明物体：
  - 短期走 `Clustered Forward`
  - 中长期可选 `Visibility Buffer` 或 `Deferred`
- 透明物体：
  - 持续走 `Forward+`
- 屏幕空间效果：
  - 保持 Compute 驱动
- RT 阴影 / Path Trace：
  - 继续作为增强路径叠加
- 光源基础设施：
  - 统一走 `GPU Light Data + Clustered Light Culling`

也就是说，`Clustered` 不是某一种渲染流派的附属优化，而是未来实时光照系统的共用底座。

---

## 5. 推荐实施顺序

### Phase 0: Light Data GPU 化

这是第一优先级，且建议单独成阶段。

#### 目标

- 将 `point light / spot light` 从 `BasePassUniforms` 的固定数组中剥离
- 改为每帧上传到 GPU `storage buffer`
- 暂时保留 `directional light + CSM + IBL` 继续使用当前 uniform 方案

#### 为什么先做这个

- 这是解除 16 光源上限的最短路径
- 即使暂时还没做 culling，也已经完成了架构去硬编码
- 这一步完成后，后面的 Clustered Culling 只是在“光源来源”前面插入筛选，而不是同时重构数据模型和着色器

#### 预期收益

- 从“固定 16 点光/16 聚光”过渡到“理论上可扩展的 GPU 光源池”
- 为后续 compute culling 统一输入格式
- 降低 `BasePassUniforms` 体积

#### 需要改动的主要文件

- `src/engine/render/passes/mesh_pass.zig`
- `src/engine/render/passes/base_pass.zig`
- `assets/shaders/mesh.frag.glsl`
- `src/engine/render/renderer.zig`

#### 阶段验收

- 点光/聚光数量不再受 `16` 的编译期上限约束
- 无 clustered culling 时，渲染结果与旧路径在小光源场景下保持一致
- 现有透明物体和 RT Shadow 不回归

---

### Phase 1: 引入 Clustered Light Culling Pass

#### 目标

- 用 Compute Pass 把相机视锥切分为 3D clusters
- 构建每个 cluster 对应的光源索引列表
- 为 fragment shader 提供“当前像素所属 cluster 的可见光列表”

#### 推荐策略

- 初版优先做 `Clustered`，不要先做 `2D Tiled`
- Z 方向切分建议使用对数或近似对数分布
- 初版先只对 `point light / spot light` 做 culling
- `directional light` 继续走单独常量路径

#### 数据产物

建议至少产出以下 GPU buffer：

- `LightDataBuffer`
  - 全局点光/聚光数据池
- `ClusterLightGrid`
  - 每个 cluster 对应的 `offset + count`
- `ClusterLightIndices`
  - 紧凑光源索引列表
- 可选 `ClusterDebugStats`
  - 统计每帧最大 cluster 光源数、溢出次数、平均命中数

#### 与 RenderGraph 的关系

当前不建议为了这一步先重构整个 RenderGraph 执行器。

更实际的落法是：

- 像 SSAO / SSGI 一样，先在 `renderer.drawFrame()` 里手工插入 `LightCullingPass`
- 在 RenderGraph 中先把它作为逻辑 pass 记录统计与依赖意图
- 等 buffer 资源管理成熟后，再把它升级为真正由 RenderGraph 驱动的执行节点

#### 推荐新增文件

- `src/engine/render/passes/light_culling_pass.zig`
- `assets/shaders/light_culling.comp.glsl`
- `src/engine/render/clustered_lighting.zig`

#### 阶段验收

- 每帧成功生成 cluster light list
- 能输出调试信息：cluster 数量、每 cluster 命中光源分布、是否溢出
- 小场景与无 culling 直扫路径结果一致

---

### Phase 2: 将主管线升级为 Forward+

#### 目标

- 让 `mesh.frag.glsl` 不再遍历全局所有 point/spot light
- 改为：
  1. 根据像素位置和深度求 cluster id
  2. 从 `ClusterLightGrid` 取 `offset + count`
  3. 遍历 `ClusterLightIndices` 中该 cluster 的局部光源

#### 这一阶段保留不动的能力

- `Depth Prepass`
- `CSM / RT Shadow`
- `IBL`
- `Skybox`
- `Transparent Base Pass`
- `Bloom / TAA / FXAA / DOF / SSR / SSAO / SSGI`

也就是说，Guava 的第一版 Forward+ 应当是“替换取灯方式”，而不是推翻整条渲染链。

#### 预期收益

- 实时主通道从“按场景光源总数线性增长”变成“按 cluster 局部命中数增长”
- 多光源场景下 fragment 开销显著下降
- 透明物体天然复用同一套 Forward+ 光照基础设施

#### 主要改动文件

- `assets/shaders/mesh.frag.glsl`
- `src/engine/render/passes/base_pass.zig`
- `src/engine/render/passes/mesh_pass.zig`
- `src/engine/render/renderer.zig`

#### 阶段验收

- 主管线默认运行在 `Forward+`
- 大量点光/聚光场景帧时间相比“全局直扫”明显下降
- 透明路径仍正确工作

---

### Phase 3: 稳定性与性能优化

在 Forward+ 跑通以后，再做第二轮工程化优化。

#### 建议项

- Light list 溢出保护与回退策略
- 按类型拆分 point / spot list
- 更高效的 prefix sum / compaction
- Cluster 深度切分参数可配置
- Cluster occupancy 调试面板
- 针对小场景自动走简化路径

#### 编辑器支持

建议为渲染调试面板增加：

- Cluster 维度显示
- 总 cluster 数
- 最大每 cluster 光源数
- 平均每 cluster 光源数
- 溢出次数
- 全局光源总数

这样可以让这套系统从一开始就是“可观测”的，而不是黑盒。

---

### Phase 4: 向 Hybrid Renderer 扩展

当 `Clustered Forward+` 稳定后，再评估是否值得为不透明物体增加第二条路径：

- `Visibility Buffer`
- 或 `G-Buffer + Lighting Pass`

此时 Guava 将拥有：

- 不透明路径可选更激进的带宽/吞吐优化方案
- 透明路径继续复用 `Forward+`
- Clustered Light 基建作为两条路径的共享底座

这才是更合理的 Hybrid Renderer 终局。

---

## 6. 不建议本阶段做的事

以下事项不建议绑定在第一轮升级里一起推进：

- 先做完整 Deferred 再回头补透明 Forward+
- 同时重构 RenderGraph 执行器、资源系统、主管线和材质系统
- 一开始就追求 bindless 全量改造
- 一开始就把 directional light 也并入 clustered list
- 在第一版就同时做 Visibility Buffer 和 Forward+

原因很简单：这些都不是当前收益最大的瓶颈点。

---

## 7. 里程碑建议

### M1: GPU Light Data

- 去掉 point/spot 的固定 uniform 上限
- 小场景结果对齐旧版

### M2: Light Culling Pass

- 成功生成 cluster light list
- 提供基础统计与调试输出

### M3: Forward+ 上线

- `mesh.frag.glsl` 改为按 cluster 取灯
- 大光源场景性能明显提升

### M4: Hybrid 预留完成

- Light data / cluster data 已成为共享基础设施
- 不透明路径未来可插入 `Visibility Buffer` 或 `Deferred`

---

## 8. 建议的源码落点

为了让这条路线尽量少扰动现有结构，推荐按以下边界组织代码：

### 8.1 新增模块

- `src/engine/render/clustered_lighting.zig`
  - cluster 维度计算
  - CPU 侧参数准备
  - GPU buffer 描述和辅助函数
- `src/engine/render/passes/light_culling_pass.zig`
  - compute pass 生命周期
  - pipeline / sampler / buffer 绑定
- `assets/shaders/light_culling.comp.glsl`
  - cluster 构建与光源筛选

### 8.2 修改模块

- `src/engine/render/passes/mesh_pass.zig`
  - 缩减 `BasePassUniforms`
  - 引入面向 GPU buffer 的 light data 定义
- `src/engine/render/passes/base_pass.zig`
  - 给主材质 pass 增加 clustered light buffer 绑定
- `assets/shaders/mesh.frag.glsl`
  - 从“全局直扫 light array”改为“按 cluster 取灯”
- `src/engine/render/renderer.zig`
  - 在 depth prepass 与 base pass 之间或之前插入 `LightCullingPass`
- `src/engine/render/render_graph.zig`
  - 先补逻辑 pass 语义与统计项
  - 后续再扩展 buffer 资源类型

---

## 9. 一句话路线图

Guava Engine 的下一步不应该是“从前向直接跳到纯延迟”，而应该是：

**先把当前前向主管线升级成 Clustered Forward+，再在这套共享光照基础设施之上，逐步扩展出真正的 Hybrid Renderer。**

这条路径风险最低、收益最直接，也最符合 Guava 当前代码和团队阶段。
