# Guava Engine 开发计划

## 项目概述

Guava Engine 是一个使用 Zig 语言开发的游戏引擎，目前处于活跃开发阶段。

&gt; **注意**: 本文档基于代码实际状态编写，与旧文档可能存在差异。

---

## 已实现的系统

### 1. 渲染系统

**状态**: 基础功能已实现

| 功能 | 文件路径 | 状态 |
|------|----------|------|
| RenderGraph 架构 | `render/render_graph.zig` | ✅ |
| Depth Prepass | `render/depth_prepass.zig` | ✅ |
| Base Pass PBR 渲染 | `render/base_pass.zig` | ✅ |
| Shadow Pass 级联阴影 | `render/shadow_pass.zig` | ✅ |
| IBL 环境光照 | `render/ibl_precompute.zig` | ✅ |
| Skybox | `render/skybox_pass.zig` | ✅ |
| Bloom 后处理 | `render/bloom_pass.zig` | ✅ |
| Tonemap | `render/tonemap_pass.zig` | ✅ |
| FXAA 抗锯齿 | `render/fxaa_pass.zig` | ✅ |
| Gizmo 绘制 | `render/gizmo_pass.zig` | ✅ |
| Outline 选择高亮 | `render/outline_pass.zig` | ✅ |

**待完善**:
- [ ] SSAO (屏幕空间环境光遮蔽)
- [ ] SSR (屏幕空间反射)
- [ ] TAA (时域抗锯齿)
- [ ] DOF (景深)
- [ ] 点光 Cube Shadow

---

### 2. 物理系统

**状态**: MVP 已实现，基于 Jolt Physics

| 功能 | 文件路径 | 状态 |
|------|----------|------|
| Jolt C++ 桥接层 | `physics/jolt_bridge.cpp` | ✅ |
| Rigidbody 组件 (static/dynamic/kinematic) | - | ✅ |
| BoxCollider / SphereCollider / MeshCollider | - | ✅ |
| 固定步长物理更新 | `application.zig` (physics_accumulator) | ✅ |
| 持久化 Body 缓存架构 (事件驱动增量更新) | - | ✅ |
| Trigger 事件系统 (enter/stay/exit) | - | ✅ |
| Debug Draw 可视化 (Box/Sphere 线框) | - | ✅ |
| Constraints 约束系统 (Point/Hinge/Slider/Distance) | - | ✅ |
| Layer 基础架构 (layer_id/layer_group 字段) | - | ✅ |

**待完善**:
- [ ] C++ 层 Layer 碰撞过滤完整实现
- [ ] 物理查询 API (射线检测、形状投射、重叠检测)
- [ ] 约束可视化
- [ ] 约束马达和弹簧设置

---

### 3. 动画系统

**状态**: MVP 已实现

| 功能 | 状态 |
|------|------|
| Skeleton/Skin/AnimationClip 资源 | ✅ |
| SkinnedMesh/Animator 组件 | ✅ |
| glTF skins/animations/JOINTS_0/WEIGHTS_0 导入 | ✅ |
| Clip 采样与播放 (`animator_system.zig`) | ✅ |
| 顶点变形 (GPU skinning) | ✅ |
| 基础 Cross-fade 混合 | ✅ |

**待完善**:
- [ ] 动画状态机 (Animator Controller)
- [ ] 1D/2D Blend Tree
- [ ] Upper/Lower Body 分层混合
- [ ] 动画事件系统

---

### 4. 脚本系统

**状态**: MVP 已实现，支持内置脚本运行

| 功能 | 文件路径 | 状态 |
|------|----------|------|
| Script 组件定义 | `script/types.zig` | ✅ |
| ScriptContext API (Transform 操作、实体查询) | `script/context.zig` | ✅ |
| ScriptRuntime 运行时管理 | `script/runtime.zig` | ✅ |
| VM 抽象接口 | `script/vm.zig` | ✅ |
| ZigVM 内置脚本实现 (rotate/patrol/fly_camera/fps_controller) | `script/vm.zig` | ✅ |
| 脚本生命周期回调 (OnInit/OnUpdate/OnDestroy) | `script/vm.zig` | ✅ |
| 输入系统 API 暴露给脚本 | `script/context.zig` | ✅ |
| 时间系统 API 暴露给脚本 | `script/context.zig` | ✅ |
| 热重载机制 | `script/hot_reload.zig` | ✅ (基础实现) |
| C# VM 存根 | `script/vm.zig` | ✅ (存根) |

**待实现**:
当前引擎仅支持 zig 编写和 c#语言，官方不支持其他语言，但保留 API 接口，三方可自己实现
- [ ] Zig 脚本动态编译 (目前使用内置脚本作为替代方案)
- [ ] C# 完整支持（.net10）
- [ ] 脚本调试器

---

### 5. 资产系统

**状态**: 已实现

| 功能 | 状态 |
|------|------|
| AssetRegistry 资产注册表 | ✅ |
| 异步资产加载 (JobSystem) | ✅ |
| glTF 导入 (`assets/gltf_import.zig`) | ✅ |
| 纹理导入与解码 | ✅ |
| 材质资源 | ✅ |
| Mesh 资源 | ✅ |
| 环境贴图资源 | ✅ |

---

### 6. 场景系统

**状态**: 已实现

| 功能 | 文件路径 | 状态 |
|------|----------|------|
| ECS 架构 (World/Entity/Component) | - | ✅ |
| 层级变换系统 | - | ✅ |
| Scene Extraction 场景提取 | - | ✅ |
| BVH 空间索引 | `scene/spatial_index.zig` | ✅ |
| 视锥剔除 | - | ✅ |
| 射线检测 | - | ✅ |
| 场景序列化 v5 | - | ✅ |

---

### 7. 编辑器

**状态**: 基础功能已实现

| 功能 | 状态 |
|------|------|
| Dock 布局系统 | ✅ |
| Scene Hierarchy 场景层级 | ✅ |
| Inspector 属性检查器 | ✅ |
| 视口与相机控制 | ✅ |
| Gizmo 变换工具 (平移/旋转/缩放) | ✅ |
| 资源浏览器 | ✅ |
| Material Editor 材质编辑器 UI | ✅ |
| Undo/Redo 命令化历史 | ✅ |
| 多语言支持 (i18n) | ✅ |

**待完善**:
- [ ] 动画编辑器 (只有 UI 框架)
- [ ] 多视口支持
- [ ] 相机书签

---

### 8. 核心系统

**状态**: 已实现

| 功能 | 状态 |
|------|------|
| Application 主循环 | ✅ |
| JobSystem 任务系统 | ✅ |
| Input 输入系统 | ✅ |
| Layer 层系统 | ✅ |
| Window 窗口抽象 (SDL) | ✅ |
| RHI 渲染硬件接口 | ✅ |

---

## 当前主要缺口

### 🔴 高优先级 (阻塞游戏开发)

| 优先级 | 任务 | 描述 |
|--------|------|------|
| 1 | **Zig 脚本动态编译** | 将项目脚本从内置 builtin 过渡到真实动态编译工作流 |
| 2 | **物理查询 API** | 射线检测命中物理物体；形状投射；重叠检测 |
| 3 | **动画状态机** | 基础状态机实现；状态过渡 |

### 🟡 中优先级 (提升开发体验)

| 优先级 | 任务 | 描述 |
|--------|------|------|
| 4 | **编辑器完善** | 动画编辑器功能实现；多视口支持 |
| 5 | **渲染效果** | SSAO；SSR |

### 🟢 低优先级 (Polish)

| 优先级 | 任务 | 描述 |
|--------|------|------|
| 6 | **高级功能** | TAA；DOF；点光 Cube Shadow |

---

## 详细缺口清单

### 核心编辑功能缺失

#### 1. Prefab
- [ ] prefab系统不完善

#### 2. 动画编辑器
- [ ] 虽然引擎有 `animator_system.zig` 和 `animation_clip_resource.zig`，但编辑器缺少可视化的动画编辑界面
- [ ] 没有 Animation Graph/状态机编辑器
- [ ] 缺少动画混合、过渡时间线编辑
- [ ] 无法可视化骨骼层级和蒙皮

#### 3. 物理可视化
- [ ] 渲染设置中虽然有 `show_collision` 开关，但功能有限
- [ ] 缺少碰撞体的可视化编辑工具（如 BoxCollider/SphereCollider 的尺寸可视化调整）
- [ ] 没有 Physics Debug View 显示刚体速度、力等调试信息
- [ ] 缺少物理调试工具（如施加力、暂停物理模拟）

---

### 工作流程工具

#### 4. 搜索和过滤
- [ ] 场景层级有基础的 filter，但缺少强大的全局搜索
- [ ] 没有按组件类型搜索实体
- [ ] 缺少按名称/标签搜索资源
- [ ] 没有最近的文件/场景快速访问

#### 5. 多视口支持
- [ ] 当前只有一个 3D 视口
- [ ] 缺少多视口布局（如前/顶/侧视图同时显示）
- [ ] 没有 2D 纹理/贴图视口用于 UV 编辑

#### 6. 书签和相机预设
- [ ] 无法保存和切换相机位置
- [ ] 缺少场景书签（快速跳转到特定位置）
- [ ] 没有相机漫游路径录制

---

### 调试和分析工具

#### 7. 性能分析器
- [ ] 虽然有基本的 FPS 显示，但缺少详细的分析工具
- [ ] 没有 GPU/CPU 时间线
- [ ] 缺少内存使用分析
- [ ] 没有绘制调用、三角形统计的可视化

#### 8. 网络/多人编辑
- [ ] 完全缺少多人协作编辑功能
- [ ] 没有实时同步机制
- [ ] 缺少用户标识和权限管理

#### 9. 版本控制集成
- [ ] 没有与 Git 集成的界面
- [ ] 缺少场景/资源的 diff 可视化
- [ ] 没有 merge 冲突解决工具

---

### 高级功能

#### 10. 粒子系统编辑器
- [ ] 只有基础的 VFX 组件（如 fountain、orbit）
- [ ] 缺少可视化的粒子系统编辑器
- [ ] 没有粒子发射器、力场的可视化编辑
- [ ] 无法实时预览粒子效果

#### 11. 后处理管线编辑器
- [ ] 虽然有 Bloom、FXAA、Color Grading 等后处理效果，但缺少图形化编辑器
- [ ] 无法可视化调整后处理效果
- [ ] 缺少后处理效果预设管理

#### 12. 脚本编辑器
- [ ] 项目有 `script/` 目录，但编辑器没有集成的脚本编辑器
- [ ] 缺少代码自动完成
- [ ] 没有脚本调试器
- [ ] 无法在编辑器中编辑并立即运行脚本

---

### UI/UX 改进

#### 13. 主题定制
- [ ] 只有一种深色主题
- [ ] 无法自定义颜色方案
- [ ] 缺少高对比度/浅色主题

#### 14. 快捷键系统
- [ ] 虽然有快捷键，但没有可视化快捷键编辑器
- [ ] 无法自定义快捷键
- [ ] 缺少快捷键冲突检测

#### 15. 拖放增强
- [ ] 拖放功能有限，只支持资源到场景
- [ ] 无法拖放实体到层级
- [ ] 缺少拖放排序功能

---

### 资源管理

#### 16. 资源依赖图
- [ ] 没有可视化资源依赖关系
- [ ] 缺少未使用资源检测
- [ ] 无法批量重新导入资源

#### 17. 资源版本管理
- [ ] 缺少资源历史记录
- [ ] 无法回滚到之前的资源版本
- [ ] 没有资源引用追踪

---

### 文档和帮助（暂时不做）

#### 18. 上下文帮助
- [ ] 没有 tooltip 帮助
- [ ] 缺少在线文档链接
- [ ] 没有新手教程



## 当前剩余硬伤

- [P1] 层级递归现在已经改为沿用精确世界矩阵向下传播，主问题不再是“误差层层放大”；但对外暴露的 `world_transform_cache` 仍然来自矩阵分解，所以在“父节点非均匀缩放 + 子节点旋转”这类存在 shear 的场景下，`world` TRS 依旧只是近似值。
- [P2] 动画图/状态机虽然已经补齐了参数条件、`time_remaining` 条件和条件所有权，但它仍未接入 `Animator` 主运行时，当前更像独立模块而不是正式动画控制器。
