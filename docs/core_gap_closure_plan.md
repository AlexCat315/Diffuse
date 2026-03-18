# Guava Engine 核心缺口补齐落地计划（已更新 - 删除已实现部分）

本文基于当前仓库实现状态编写，目标是把已经识别出的核心缺口转成可执行的实施顺序。本文不提供时间估算，只定义依赖关系、阶段目标、交付物、完成标准与延后策略。


请注意，在完成功能时，必须做好日志和中文注释

## 已实现阶段总结

截至最新更新，以下阶段已经**完整实现**：

- ✅ **P0**: 验收基线与回归骨架 - 已完成（基准测试、黄金图像、报告系统）
- ✅ **P1**: 运行时数据层重构 - 已完成（Transform、层级缓存、包围体、glTF导入语义修正）
- ✅ **P2**: 场景提取与渲染数据模型重构 - 已完成（Scene Extraction、RenderWorld、PreparedScene结构）
- ✅ **P3**: 异步资产管线与JobSystem - 已完成（后台加载、GPU上传队列、资产状态管理）
- ✅ **P4**: 材质系统2.0 - 已完成（PBR BRDF、纹理色彩空间、移除硬编码Tonemap、BindGroup稳定接口）
- ✅ **P6**: 阴影系统 - 已完成（方向光ShadowPass、CSM基础框架）

## 已完成专项收敛（不单列阶段）

以下内容不单独作为 P 阶段管理，但已经明显改变了编辑器与运行时的基础质量，应明确记录：

- ✅ **Undo/Redo 命令化**：历史系统已切到 `EditorCommand` 驱动，高频操作优先走 `subtree_delta`，仅保留 `scene_snapshot` 作为未细化入口的回退兜底。
- ✅ **VFX 运行时剥离**：粒子与 emitter 运行时已从 `EditorState` 下沉到 `World`，编辑器只保留选择和工具状态。
- ✅ **粒子 SoA 存储**：VFX 粒子运行时已使用 `std.MultiArrayList`，为缓存友好更新和后续 SIMD 优化预留空间。
- ✅ **视口输入隔离**：视口交互已区分 UI 覆盖层与 3D 区域，支持 FPS 展示位置切换，调试层默认关闭。
- ✅ **变换工具累计偏移**：平移、旋转、缩放的吸附逻辑已改为“基于单次拖拽原点的累计计算”，避免逐帧 snap 吃掉慢速拖拽精度。

补充实现说明见：

- `docs/editor_interaction_runtime_notes.md`

## 剩余缺口清单

未实现或部分实现的核心功能：

- **P5**: IBL、Skybox、HDR与后处理 - 部分实现（IBL资源链、Skybox、Tonemap、手动Exposure、Bloom MVP、Color Grading MVP、FXAA MVP 已落地，LUT待补）
- **P7**: 剔除、BVH与射线检测重构 - 有Frustum基础，未完整集成
- **P8**: 动画系统 - 未实现（无Skeleton、Clip、Skinning）
- **P9**: 物理系统 - 未实现（无Rigidbody、Collider、物理模拟）
- **P10**: 脚本与Gameplay - 未实现（无脚本组件、热重载）

## 仍需继续补齐的编辑器专项

以下问题不再属于“完全缺失”，但还没有达到可以封账的程度：

- **E1**: 视口 Overlay Capture 规则统一
  - 当前已能阻断大部分输入穿透，但仍部分依赖 `isItemHovered()` 与拖拽起点锁存。
  - 后续应收敛到更明确的 active item / window capture 规则，减少悬停瞬时状态带来的脆弱性。
- **E2**: 编辑器交互参数外部配置化
  - 相机和 manipulator 的关键手感参数已经提升为状态字段。
  - 但还没有迁移到 JSON 或用户偏好文件，也未支持热加载。
- **E3**: 历史系统剩余入口命令化
  - 高频路径已经不再依赖整场景快照。
  - 但 inspector / 资源编辑等低频路径仍存在 `scene_snapshot` 回退。
- **E4**: 主题与样式常量治理
  - 一部分 UI 颜色、按钮样式和 overlay 视觉参数仍然散落在界面代码中。
  - 需要后续集中到主题层，避免继续复制粘贴。

## 当前状态结论（精简）

- 渲染管线具备基础结构（DepthPrepass、BasePass、ShadowPass），并且PBR材质基线已补齐。
- 材质数据结构已扩展为完整PBR，Shader实现已包括标准PBR与法线贴图。
- glTF导入保留节点层级，支持骨骼动画所需数据结构，但运行时动画系统未实现
- 场景提取已完成，具备RenderWorld和PreparedScene，但缺少BVH加速结构
- 资产系统完全异步化，具备JobSystem和GPU上传管理
- 物理、脚本系统完全未实现

## 剩余执行顺序

建议按照以下顺序推进剩余工作：

### 下一阶段（高优先级）

1. **P5**: IBL、Skybox、HDR与后处理
   - ✅ 环境贴图资源通路 (已支持 HDR 解码)
   - ✅ Skybox绘制
   - ✅ 生成并缓存 irradiance map、prefiltered env map、BRDF LUT
   - ✅ HDR颜色缓冲与后处理链（Tonemap已实现为单Pass）
   - ✅ 手动 Exposure（视口级开关与倍率调节）
   - ✅ Bloom MVP（单 pass 亮部提取 + 邻域模糊）
   - ✅ Color Grading MVP（视口级 Saturation / Contrast / Gamma）
   - ✅ FXAA MVP（LDR fullscreen pass，叠加层绘制前执行）
   - LUT 待补

### 中期阶段

3. **P7**: 剔除、BVH与射线检测重构
   - 基于Scene Extraction的视锥体剔除
   - 静态BVH构建（服务剔除与射线检测）
   - Raycast升级为broad phase + narrow phase

4. **P8**: 动画系统MVP
   - SkeletonResource、SkinResource、AnimationClipResource
   - SkinnedMesh、Animator、AnimationState组件
   - glTF导入skin、joints、inverseBindMatrices、animations
   - GPU Vertex Skinning实现
   - 基础Clip混合与Cross-fade

### 后期阶段

5. **P9**: 物理系统MVP
   - 物理抽象层设计（不直接暴露第三方库API）
   - Rigidbody、BoxCollider、SphereCollider、MeshCollider组件
   - Application固定步长更新（累积器、多tick消化）
   - Jolt物理引擎适配层
   - 物理世界与场景树同步

6. **P10**: 脚本与Gameplay MVP
   - Script组件与Script资源
   - 脚本生命周期（OnInit、OnUpdate、OnDestroy）
   - 基础场景API暴露
   - 脚本热重载机制
   - 错误隔离与日志系统

## 跨阶段工程规则（保持不变）

所有阶段统一遵守以下规则：

- 每个阶段必须有单独的设计说明或章节补充，记录数据结构变化与迁移策略
- 每个阶段必须更新自动化验证，至少覆盖一个回归路径
- 每个阶段必须保留feature flag或明确的开关，避免半成品影响主流程
- 每个阶段必须输出至少一个基准场景或测试样例
- 每个阶段必须把日志、统计、错误上下文接入现有报告链路

建议新增的跨阶段产物：

- `dist/reports/` 下统一输出渲染、导入、动画与物理报告
- `assets/benchmarks/` 或等价目录，收纳材质球、阴影、动画、物理基准场景
- `docs/` 下追加每阶段设计决策与兼容性说明

## 5. 详细阶段计划

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



- 完整状态机。
-  Upper/Lower Body 分层。
- 压缩与重定向。

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

---
