# Guava Engine 核心缺口补齐落地计划

本文基于当前仓库实现状态编写，目标是把已经识别出的核心缺口转成可执行的实施顺序。本文不提供时间估算，只定义依赖关系、阶段目标、交付物、完成标准与延后策略。

本文关注的缺口包括：
- 渲染管线完整性。
- 动画系统。
- 场景剔除与空间结构。
- 物理与碰撞后端。
- 异步资产加载。
- 脚本与 Gameplay。

## 1. 总体目标

目标不是“把功能名录补齐”，而是把引擎从当前的编辑器原型态推进到可持续演进的运行时架构。所有阶段都必须服务于以下约束：

- 运行时与编辑器数据模型一致，不允许为了编辑器便利破坏运行时结构。
- 新系统必须通过可验证的验收条件进入主干。
- 新功能不能继续堆叠在同步 IO、欧拉角层级合成、扁平场景提交流程之上。
- 每一阶段结束后，仓库都必须保持可编译、可回归、可诊断。

## 2. 当前状态结论

当前实现的关键结论如下：

- `render_graph.zig` 已经有 `ShadowMap / Lighting / PostProcess` 等逻辑名词，但运行时实际执行链路仍以 `ID / DepthPrepass / BasePass / Outline / Gizmo / UI` 为主。
- 材质数据仍只有 `base_color_factor + base_color_texture`，`pbr_metallic_roughness` 目前只是命名，不是完整物理材质工作流。
- `mesh.frag.glsl` 仍是单方向光、单点光和环境项的简化直接光照，ACES 也直接写在材质 shader 内，不是真正的后处理链。
- glTF 导入器目前只覆盖静态网格通路，且会把节点变换 bake 进顶点，未保留可供骨骼动画、实例化和精确剔除使用的原始节点结构。
- 场景仍以扁平 `ArrayList(Entity)` 为核心，提交渲染与射线检测都缺少正式的 broad phase。
- 资产导入、cook、解码、加载目前都在调用线程同步执行。
- 物理、通用脚本与热重载尚未进入正式运行时架构。

因此，正确顺序不是“先加阴影或动画”，而是先补基础运行时层，再做渲染、动画、物理和脚本。

## 3. 执行顺序概览

建议按照以下顺序推进：

1. `P0` 验收基线与回归骨架。
2. `P1` 运行时数据层重构：Transform、层级缓存、包围体、导入语义修正。
3. `P2` 场景提取与渲染数据模型重构。
4. `P3` 异步资产管线与主线程 GPU 上传。
5. `P4` 材质系统 2.0 与真实 PBR 基线。
6. `P5` IBL、Skybox、HDR 与后处理。
7. `P6` 阴影系统。
8. `P7` 剔除、BVH 与射线检测重构。
9. `P8` 动画系统 MVP。
10. `P9` 物理系统 MVP。
11. `P10` 脚本与 Gameplay MVP。

并行原则：

- `P0` 必须最先完成。
- `P1` 完成前，不进入动画与物理实现。
- `P2` 和 `P3` 可以局部并行，但都必须先于完整渲染扩展。
- `P4-P6` 共同构成渲染可用线，必须连续推进。
- `P7` 可以在 `P4` 之后提前插入，但不能早于 `P1`。
- `P8` 依赖 `P1` 与 `P2`，并受益于 `P7` 的 bounds/BVH 基础。
- `P9` 依赖 `P1`，且要求 `Application` 主循环已经具备固定步长接口。
- `P10` 最好在 `P9` 之后执行，避免脚本 API 反复变更。

## 4. 跨阶段工程规则

所有阶段统一遵守以下规则：

- 每个阶段必须有单独的设计说明或章节补充，记录数据结构变化与迁移策略。
- 每个阶段必须更新自动化验证，至少覆盖一个回归路径。
- 每个阶段必须保留 feature flag 或明确的开关，避免半成品影响主流程。
- 每个阶段必须输出至少一个基准场景或测试样例。
- 每个阶段必须把日志、统计、错误上下文接入现有报告链路。

建议新增的跨阶段产物：

- `dist/reports/` 下统一输出渲染、导入、动画与物理报告。
- `assets/benchmarks/` 或等价目录，收纳材质球、阴影、动画、物理基准场景。
- `docs/` 下追加每阶段设计决策与兼容性说明。

## 5. 详细阶段计划

### P0 验收基线与回归骨架

### 目标

把后续所有改动挂到可验证的基线上，避免“功能做了，但无法判断是不是变差”。

### 主要任务

- 建立三类基准场景：
- 材质与光照基准场景。
- 阴影基准场景。
- 导入与动画基准场景占位。
- 固化当前渲染输出的黄金图与差分阈值。
- 固化当前资产导入与场景加载的报告输出。
- 补充 `zig build test` 必经的系统级 smoke test。
- 明确每个阶段的验收入口命令与报告路径。

### 主要改动范围

- `docs/architecture_acceptance.md`
- `src/engine/render/renderer.zig`
- `src/engine/assets/validator.zig`
- `src/main.zig`

### 完成定义

- 仓库可以稳定输出渲染报告、资产验证报告与黄金图差分结果。
- 至少存在一组固定场景可用于后续每阶段回归。
- 任何阶段结束后，都能直接对比“改动前后渲染与统计差异”。

### 本阶段不做

- 不修功能缺口本身。
- 不引入新渲染特性。

### P1 运行时数据层重构

### 目标

为动画、物理、剔除和稳定渲染建立正确的数据底座。

### 主要任务

- 将运行时 Transform 从“仅欧拉角表示”升级为适合组合、插值与同步的形式：
- 运行时建议使用 `translation + quaternion + scale`。
- 编辑器 UI 仍可保留欧拉角显示与编辑，但不能作为运行时真值。
- 为世界层级建立 `world transform cache` 与 dirty 传播。
- 为网格资源建立 `local bounds`。
- 为实体建立 `world bounds` 计算与缓存。
- 修正 glTF 导入语义：
- 不再把节点局部变换直接 bake 到顶点后丢失节点结构。
- 导入后保留节点层级与局部变换。
- 调整序列化与反序列化，支持新 Transform 结构与 bounds 缓存策略。

### 主要改动范围

- `src/engine/scene/components.zig`
- `src/engine/scene/world.zig`
- `src/engine/math/`
- `src/engine/assets/mesh_resource.zig`
- `src/engine/assets/gltf_import.zig`
- `src/engine/scene/scene_io.zig`

### 完成定义

- 层级变换不再通过欧拉角直接相加得到最终姿态。
- 运行时可稳定产出 world matrix。
- 网格与实体都可查询本地/世界包围盒。
- glTF 导入后的节点层级、局部姿态与资源引用可保留，不再退化成 baked 静态结果。

### 风险与注意事项

- 这是全局性结构变化，必须优先处理兼容与迁移。
- 如果此阶段处理不彻底，后面的动画、物理与阴影都会返工。

### P2 场景提取与渲染数据模型重构

### 目标

把“Scene/World 的编辑数据”与“Render 提交数据”分层，避免继续在 `prepareScene()` 内直接混合遍历、光照选择、资源解析和 draw item 组装。

### 主要任务

- 引入明确的 Scene Extraction 阶段。
- 定义 `RenderWorld`、`RenderableProxy` 或等价结构。
- 把相机、灯光、可渲染对象、调试对象从 `World` 提取到帧级只读结构。
- 把 `PreparedScene` 从简单 draw item 数组提升为明确的提交数据块：
- 相机块。
- 灯光块。
- 不透明对象块。
- 透明对象块。
- 调试可视化块。
- 为后续剔除、阴影、动画 skinning 与多 pass 重用留出接口。

### 主要改动范围

- `src/engine/render/mesh_pass.zig`
- `src/engine/render/renderer.zig`
- `src/engine/scene/world.zig`
- 新增 `src/engine/render/scene_extraction.zig` 或等价模块

### 完成定义

- `Renderer` 不再直接从 `World.entities` 临时拼装渲染提交数据。
- 后续增加阴影、IBL、动画 skinning 时，不需要再改写整个提交流程。

### 本阶段不做

- 不引入新画面特性。
- 不在本阶段完成剔除算法，只建立提取边界。

### P3 异步资产管线与 GPU 上传

### 目标

把同步导入和解码从主线程移出，让编辑器在加载中大型资源时仍能交互。

### 主要任务

- 实现 `TaskSystem` 或 `JobSystem`。
- 将以下工作移到后台线程：
- 纹理解码。
- glTF JSON 解析。
- buffer/image 读取。
- cook 与 cache 命中检测。
- 定义后台结果结构：
- CPU 解码结果。
- 导入日志与错误。
- 依赖解析结果。
- 定义主线程上传队列：
- 统一提交 buffer/image 上传。
- 统一管理 staging 生命周期。
- 引入加载状态与占位资源。
- 为资产浏览器与 inspector 提供“正在导入/等待上传/失败”状态。

### 主要改动范围

- `src/engine/assets/registry.zig`
- `src/engine/assets/texture_import.zig`
- `src/engine/assets/gltf_import.zig`
- `src/engine/assets/library.zig`
- `src/engine/render/renderer.zig`
- `src/editor/assets/browser.zig`

### 完成定义

- 导入大型 glTF 与高分辨率贴图时，主线程不再长时间阻塞。
- GPU 上传有统一入口，而不是散落在各资源创建路径中。
- 资产失败时，编辑器可见失败原因与阶段。

### 风险与注意事项

- 资源库需要明确线程边界；后台线程不得直接写 GPU 对象。
- 必须先定义上传所有权与错误回收路径。

### P4 材质系统 2.0 与真实 PBR 基线

### 目标

把当前“材质名义上是 PBR，运行时实际上不是”的状态修正为完整最小 PBR。

### 主要任务

- 扩展材质资源定义：
- `base_color`
- `normal`
- `metallic_roughness`
- `ao`
- `emissive`
- `alpha mode`
- `double sided`
- 规定纹理色彩空间：
- BaseColor/Emissive 走 sRGB。
- Normal/MetallicRoughness/AO 走 Linear。
- 扩展 glTF 导入器：
- 读取 `normalTexture`。
- 读取 `metallicRoughnessTexture`。
- 读取 `occlusionTexture`。
- 读取 `emissiveTexture` 与 emissive factor。
- 改写基础 shader：
- 引入标准 PBR BRDF 计算。
- 去掉材质 shader 内部直接做的 tonemap。
- 让 `shading model` 真正参与运行时分支或变体。
- 为材质实例化与 bind group 布局留出稳定接口。

### 主要改动范围

- `src/engine/assets/material_resource.zig`
- `src/engine/assets/gltf_import.zig`
- `src/engine/render/mesh_pass.zig`
- `assets/shaders/mesh.vert.glsl`
- `assets/shaders/mesh.frag.glsl`
- `src/editor/ui/windows/material_editor.zig`

### 完成定义

- 粗糙度与金属度对高光响应真实有效。
- 法线贴图与 AO 能进入渲染路径。
- 材质资源不再只围绕 base color 组织。
- “PBR Metallic Roughness” 不再只是 UI 名词。

### 本阶段不做

- 不引入 Shader Graph。
- 不处理完整材质节点系统。

### P5 IBL、Skybox、HDR 与后处理

### 目标

建立现代画面质量的基础链路，让材质和光照表现进入正确空间。

### 主要任务

- 引入环境贴图资产或等价资源通路。
- 支持 Skybox 绘制。
- 生成并缓存：
- `irradiance map`
- `prefiltered env map`
- `BRDF LUT`
- 将主颜色缓冲升级为 HDR 格式。
- 正式引入后处理链：
- Bloom
- Exposure
- Tonemap
- FXAA
- 允许后续插入 Color Grading、LUT、TAA。
- 把 ACES 从材质 shader 移到后处理 pass。

### 主要改动范围

- `src/engine/render/render_graph.zig`
- `src/engine/render/renderer.zig`
- 新增 `src/engine/render/post_*.zig`
- 新增 `src/engine/render/skybox_*.zig`
- 新增环境贴图处理模块

### 完成定义

- 场景主渲染进入 HDR，再由后处理输出到 swapchain。
- 环境反射、粗糙度响应与间接光照表现合理。
- 后处理效果具备独立开关与明确顺序。

### 风险与注意事项

- 如果在真实 HDR 与 IBL 之前先上 Bloom 或 TAA，会制造后续重写。

### P6 阴影系统

### 目标

建立可控、稳定、可调试的阴影通路。

### 主要任务

- 先实现方向光 shadow pass。
- 再扩展为 `CSM`：
- cascade 划分策略。
- 稳定化相机。
- 偏移与过滤。
- 提供阴影调试可视化：
- cascade 边界。
- shadow map 预览。
- 深度 bias 与过滤参数。
- 点光 Cube Shadow 放在本阶段尾部或后续扩展，不作为先决条件。

### 主要改动范围

- `src/engine/render/render_graph.zig`
- `src/engine/render/renderer.zig`
- 新增 `src/engine/render/shadow_pass.zig`
- 相关 shader 与资源布局

### 完成定义

- 户外基准场景具备稳定方向光阴影。
- 阴影参数可调、结果可诊断。
- 渲染图中的 `ShadowMap` 不再只是概念资源。

### 本阶段不做

- 不以点光阴影完备性为阻塞项。
- 不在此阶段引入复杂 GI。

### P7 剔除、BVH 与射线检测重构

### 目标

让大场景 CPU 提交与编辑器选择成本进入可控范围。

### 主要任务

- 在 Scene Extraction 前计算视锥体平面。
- 用世界包围盒做 frustum culling。
- 建立静态 BVH：
- 服务视锥体剔除。
- 服务编辑器射线检测。
- 动态对象先采用增量更新或分区列表。
- 让 raycast 从“逐实体逐三角全扫”升级为 broad phase + narrow phase。
- 让碰撞可视化复用 bounds/BVH 数据，不再仅靠临时线框计算。

### 主要改动范围

- `src/engine/render/mesh_pass.zig`
- `src/engine/scene/raycast.zig`
- `src/engine/scene/world.zig`
- 新增空间结构模块

### 完成定义

- 屏幕外对象不再进入主要 draw item 列表。
- 编辑器 pick 与射线检测性能不再随总三角数线性退化。
- BVH 与 bounds 成为后续物理和可见性系统的共享基础。

### P8 动画系统 MVP

### 目标

建立从导入到运行时播放再到基础混合的动画闭环。

### 主要任务

- 定义动画核心资源：
- `SkeletonResource`
- `SkinResource`
- `AnimationClipResource`
- 定义运行时组件：
- `SkinnedMesh`
- `Animator`
- `AnimationState`
- 扩展 glTF 导入：
- `skins`
- `joints`
- `inverseBindMatrices`
- `animations`
- `JOINTS_0`
- `WEIGHTS_0`
- 实现动画采样：
- 位置与缩放线性插值。
- 旋转球面插值。
- 实现 matrix palette skinning：
- 首选 GPU vertex skinning。
- 必要时保留 CPU skinning debug 路径。
- 完成最小混合能力：
- clip 播放。
- clip cross-fade。
- 简单 1D blend。

### 主要改动范围

- `src/engine/assets/gltf_import.zig`
- `src/engine/assets/mesh_resource.zig`
- `src/engine/scene/components.zig`
- 新增 `src/engine/animation/`
- 渲染 shader 与提交数据结构

### 完成定义

- 单角色可播放导入骨骼动画。
- 编辑器与运行时播放结果一致。
- 两段 clip 间可平滑过渡。
- “show bones” 不再只是父子节点线段，而是真实 skeleton debug 绘制。

### 本阶段不做

- 不先做完整状态机。
- 不先做 Upper/Lower Body 分层。
- 不先做压缩与重定向。

### P9 物理系统 MVP

### 目标

建立基础物理仿真、碰撞查询与运行时同步链路。

### 主要任务

- 先定义物理抽象层，不把第三方库 API 直接扩散到引擎核心。
- 引入组件：
- `Rigidbody`
- `BoxCollider`
- `SphereCollider`
- `MeshCollider`
- 在 `Application` 中引入固定步长更新：
- 累积器。
- 多 tick 消化。
- 渲染插值接口占位。
- 集成物理后端：
- 建议先实现 Jolt 适配层。
- 实现物理世界与场景树同步：
- 从场景写入物理初始化。
- 物理 tick 后回写位置与旋转。
- 复用现有调试绘制链路做 collider/刚体可视化。

### 主要改动范围

- `src/engine/core/application.zig`
- `src/engine/scene/components.zig`
- `src/engine/scene/world.zig`
- 新增 `src/engine/physics/`
- `src/engine/render/renderer.zig` 的调试绘制入口

### 完成定义

- 固定步长物理更新与渲染帧解耦。
- 基础刚体与碰撞体可在场景中稳定运行。
- 编辑器可查看 collider 与刚体状态。
- 射线查询可以优先命中物理世界。

### 风险与注意事项

- 在 fixed update 前直接接物理，会导致同步与稳定性问题。
- 动画与物理最终会竞争 Transform 写权限，必须提前定义 owner 规则。

### P10 脚本与 Gameplay MVP

### 目标

为实体提供可扩展的通用行为层，而不是继续堆积专用内建系统。

### 主要任务

- 引入脚本组件与脚本资源。
- 定义脚本生命周期：
- `OnInit`
- `OnUpdate`
- `OnDestroy`
- 暴露基础场景 API：
- 读写 Transform。
- 查询实体与组件。
- 触发事件。
- 访问输入与时间。
- 先实现脚本层热重载。
- 原生 Zig 动态库热重载放入后续扩展，不作为 MVP 阻塞项。
- 为脚本错误建立隔离、日志与回滚机制。

### 主要改动范围

- `src/engine/scene/components.zig`
- 新增 `src/engine/script/`
- `src/engine/core/application.zig`
- `src/engine/scene/world.zig`
- 编辑器 inspector 与资源浏览器

### 完成定义

- 至少存在一个独立脚本示例，可驱动实体生命周期与场景读写。
- 脚本修改后可重载并反馈明确错误。
- Gameplay 行为不再需要直接改编辑器层代码。

### 本阶段不做

- 不先做原生模块 ABI 热重载。
- 不先做复杂调试器。

## 6. 推荐延后项

以下功能建议在上述主线完成后再进入：

- 点光 Cube Shadow。
- TAA。
- SSAO / SSR / DOF。
- 完整 Blend Tree 编辑器。
- 动画状态机编辑器。
- 原生 Zig 动态库热重载。
- 完整插件化边界。

这些项不是不重要，而是不应在底层结构未稳定前抢占优先级。

## 7. 里程碑交付要求

每个阶段结束时，必须至少交付以下内容：

- 代码进入主干且保持可编译。
- 一组与阶段目标对应的自动化测试或黄金对比。
- 一份阶段设计补充文档。
- 一组基准场景或样例资源。
- 一份报告输出，能够证明阶段能力已进入可诊断状态。

如果某阶段无法同时交付以上内容，则视为未完成，不进入下一阶段。

## 8. 首个执行批次

建议第一个执行批次只覆盖以下内容：

- `P0` 全部。
- `P1` 全部。
- `P2` 的边界建立。

原因如下：

- 不先修正 Transform、层级缓存和 glTF 导入语义，后面的动画、物理、剔除都会重复返工。
- 不先建立 Scene Extraction 边界，后续增加阴影、IBL、动画 skinning 时还会继续把逻辑塞进 `Renderer`。
- 不先建立验收基线，后面无法判断画质与性能是否真实改善。

完成首批后，再进入 `P3-P6` 的渲染主线，其后再推进 `P7-P10`。

## 9. 结论

当前仓库最需要的不是继续向外扩展 feature list，而是先完成一次“运行时底座收敛”。只要 `P0-P2` 执行到位，后续渲染、动画、物理和脚本都会进入可预测的推进方式；如果跳过这些基础阶段直接开发阴影、动画或物理，最终一定会在数据模型、提交流程和同步边界上重复返工。
