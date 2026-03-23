# Guava Engine — 功能推进文档

> **引擎语言**: Zig 0.15 | **平台**: macOS (Metal) → Windows (Vulkan/DX12) → Linux (Vulkan)
> **定位**: AI-Native 实时游戏引擎 + 离线物理渲染器（对标 Unity 编辑体验 + Blender Cycles 渲染品质）
> **上次更新**: 2025-07-13

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
│  Asset Browser   │ Timeline    │ Node Editor │ Render Settings  │
├────────────────────────────┬────────────────────────────────────┤
│       Game Runtime         │         Creation Tools            │
│  SceneManager / GameState  │  Material Editor / Anim Graph     │
│  ScriptVM (WASM/Zig)       │  UV Editor / Node Shader Editor   │
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
│  │   Metal Backend │ Vulkan Backend │ DX12 Backend         │   │
│  │   + Compute     │ + Ray Tracing  │ + Indirect Draw      │   │
│  └─────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  Platform │ Window (SDL3) │ Input (SDL3) │ File I/O │ Thread   │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 核心设计原则

1. **RHI 自研** — 图形通信用自己的抽象层直通 Metal/Vulkan/DX12，SDL3 只保留窗口/输入/音频
2. **双轨渲染** — 实时光栅用于创作迭代，离线路径追踪用于影视级出图，共享同一场景数据
3. **AI 一等公民** — AI 通过 MCP 协议直接读写场景，所有操作进 Command 管道
4. **数据驱动** — 场景 JSON v6 序列化，Inspector 双向绑定，编译期反射
5. **渐进式品质** — 每个渲染特性可独立开关，degradation graceful

### 1.3 目标参照

| 参照系 | 对标能力 | 不做的事 |
|--------|---------|---------|
| **Unity** | 编辑器布局、组件工作流、Play/Pause/Stop、Asset Pipeline | C# 脚本生态、Asset Store |
| **Blender** | 路径追踪品质（Cycles）、材质节点、相机动画、渲染输出 (4K 图片+视频) | 雕刻、绘制、流体模拟、视频编辑器 |
| **UE5** | 级联阴影、Lumen-级 GI 品质、多光源 | Nanite、World Partition、蓝图 |

---

## 二、已落地能力基线

### 2.1 渲染系统

| 能力 | 状态 | 说明 |
|------|------|------|
| RHI 层 | ✅ SDL3 GPU | 仅光栅图形管线，无 Compute/RT |
| RenderGraph | ✅ | 通道依赖管理 |
| PBR + Cook-Torrance BRDF | ✅ | mesh.frag.glsl |
| IBL 环境光 (辐照度图 + BRDF LUT) | ✅ | CPU 预计算 |
| 阴影 | ⚠️ 单 2K shadow map | 非级联，40x40 正交 |
| Depth Prepass / Skybox | ✅ | |
| Bloom / Tonemap / FXAA | ✅ | |
| SSAO | ⚠️ 32 样本已计算 | **未接入光照着色器** |
| SSR | ⚠️ 二进制搜索 | 无粗糙度模糊 |
| DOF | ✅ CoC + 模糊 + 合成 | |
| TAA | ⚠️ 管线已修复 | 未接入 drawFrame（需 jitter 注入） |
| 体积雾 | ✅ | |
| 光源 | ⚠️ max 1 方向光 + 1 点光 | LightBlock 数组已有但未启用 |
| GPU RT (Metal) | ✅ 影子 + 路径追踪 | 仅 macOS，已绕过 SDL3 |
| CPU Path Tracer | ✅ | 均匀采样，无 MIS/NEE/降噪 |
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
| 响应式布局 | ⚠️ 3 级断点，但阈值偏高，面板无最小约束 |

### 2.3 运行时系统

| 能力 | 状态 |
|------|------|
| Jolt Physics | ✅ 刚体/碰撞器/触发器/约束/Debug Draw |
| ScriptVM (WASM + Zig) | ✅ 热重载 + Inspector 参数反射，待扩展 Python/C# 前端 |
| 骨骼动画 + Animation Graph | ✅ 60% |
| Audio (SoLoud) | ⚠️ 集成但初始化有问题 |
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
| Query API (语义/空间/BVH) | ✅ |
| Schema 资源族 | ✅ |

---

## 三、RHI 层重构 — 脱离 SDL3 图形 API

### 3.1 为什么必须重构

当前 RHI 层封装 SDL3 GPU API，存在根本性限制：

| 限制 | 影响 |
|------|------|
| **无 Compute Shader** | IBL 预计算困在 CPU，SSAO/SSGI/GPU 剔除无法实现 |
| **无 Ray Tracing API** | Metal RT 被迫绕过 SDL3 独立实现，Vulkan/DX12 RT 无法接入 |
| **无 Indirect Draw** | GPU 驱动渲染不可能，大场景 draw call 无法压缩 |
| **仅 2D 纹理** | 立方体贴图用 6 张 2D 模拟，浪费内存 |
| **仅 Vertex + Fragment** | 无 Mesh Shader / Tessellation |
| **隐式同步** | 每帧 GPU 同步边界，compute dispatch 不可能异步 |

### 3.2 新 RHI 架构

```
GuavaRHI (src/engine/rhi/)
├── rhi.zig              — 公共接口定义 (trait / vtable)
├── types.zig            — 统一类型 (Buffer, Texture, Pipeline, ...)
├── metal/
│   ├── metal_device.zig — MTLDevice 封装 (Zig 调用 ObjC)
│   ├── metal_cmd.zig    — MTLCommandBuffer / Encoder
│   ├── metal_rt.zig     — Metal Ray Tracing (已有基础)
│   └── metal_shader.zig — MTLLibrary / MSL 编译
├── vulkan/              — (Phase 2)
│   ├── vk_device.zig
│   ├── vk_cmd.zig
│   ├── vk_rt.zig        — VK_KHR_ray_tracing_pipeline
│   └── vk_shader.zig    — SPIR-V
└── dx12/                — (Phase 3，可选)
```

### 3.3 RHI 公共接口

```zig
pub const RhiDevice = struct {
    // === 资源创建 ===
    createBuffer:           *const fn(BufferDesc) Error!Buffer,
    createTexture:          *const fn(TextureDesc) Error!Texture,       // 支持 2D/3D/Cube/Array
    createSampler:          *const fn(SamplerDesc) Error!Sampler,
    createGraphicsPipeline: *const fn(GraphicsPipelineDesc) Error!GraphicsPipeline,
    createComputePipeline:  *const fn(ComputePipelineDesc) Error!ComputePipeline,  // 新增
    createShaderModule:     *const fn(ShaderModuleDesc) Error!ShaderModule,

    // === 命令录制 ===
    beginFrame:       *const fn() Error!CommandBuffer,
    beginRenderPass:  *const fn(CommandBuffer, RenderPassDesc) Error!RenderPass,
    beginComputePass: *const fn(CommandBuffer) Error!ComputePass,      // 新增
    beginCopyPass:    *const fn(CommandBuffer) Error!CopyPass,
    endRenderPass:    *const fn(RenderPass) void,
    endComputePass:   *const fn(ComputePass) void,                     // 新增
    endCopyPass:      *const fn(CopyPass) void,
    submitFrame:      *const fn(CommandBuffer) Error!void,

    // === 绘制 ===
    drawIndexed:         *const fn(RenderPass, DrawIndexedArgs) void,
    drawIndirect:        *const fn(RenderPass, Buffer, u32, u32) void,  // 新增
    dispatch:            *const fn(ComputePass, u32, u32, u32) void,    // 新增
    dispatchIndirect:    *const fn(ComputePass, Buffer, u32) void,      // 新增

    // === Ray Tracing (可选能力) ===
    createAccelStructure:  *const fn(AccelStructureDesc) Error!AccelStructure,
    buildAccelStructure:   *const fn(CommandBuffer, AccelStructure) void,
    traceRays:             *const fn(ComputePass, RtPipelineState, u32, u32) void,

    // === 资源更新 ===
    uploadBufferData:  *const fn(Buffer, []const u8) void,
    uploadTextureData: *const fn(Texture, []const u8, u32) void,
    readbackTexture:   *const fn(Texture) Error![]u8,

    // === 能力查询 ===
    capabilities: Capabilities,
};

pub const Capabilities = struct {
    compute: bool,
    ray_tracing: bool,
    indirect_draw: bool,
    mesh_shaders: bool,
    texture_3d: bool,
    texture_cube_native: bool,
};
```

### 3.4 迁移策略

**关键原则：18 个渲染 Pass 零修改**。新 RHI 保持与现有 `device.zig` 完全相同的调用接口，仅底层实现从 SDL3 切换到 Metal/Vulkan 原生 API。

| 阶段 | 内容 | 依赖 |
|------|------|------|
| **RHI-1** | Metal Graphics Backend | 无 — 替换 SDL3 GPU 调用为 MTLDevice |
| **RHI-2** | Metal Compute Backend | RHI-1 — MTLComputeCommandEncoder |
| **RHI-3** | Metal RT 统一 | RHI-2 — 将 metal_rt_bridge.mm 收归 RHI |
| **RHI-4** | Vulkan Graphics Backend | RHI-1 完成后并行 |
| **RHI-5** | Vulkan Compute + RT | RHI-4 — VK_KHR_ray_tracing |

**SDL3 保留范围**：窗口创建、输入事件、音频设备、文件对话框。**不再用于任何图形调用。**

### 3.5 着色器编译策略

| 平台 | 着色器源 | 编译路径 |
|------|---------|---------|
| Metal | GLSL → SPIR-V → MSL (spirv-cross) | 离线编译，打包 .metallib |
| Vulkan | GLSL → SPIR-V (glslang) | 离线编译，打包 .spv |
| DX12 | HLSL → DXIL (dxc) | 离线编译 |

统一着色器源使用 GLSL，通过 `zig build shaders` 编译为各平台格式。manifest.json 管理所有 shader variant。

---

## 四、光栅渲染管线 — 追平现代引擎基线

### 4.1 当前差距诊断

| 问题 | 根因 | 视觉影响 |
|------|------|---------|
| 画面"平"，无空间感 | 全局 ambient 是常量，无间接光 | 致命 — 缺少颜色溢出和反弹光 |
| 远处阴影块状 | 单 2K shadow map，40 unit 正交 | 严重 — 远景阴影马赛克 |
| 无环境遮蔽 | SSAO 已计算但未接入着色器 | 严重 — 物体不接地 |
| 场景光照单调 | max 1 方向光 + 1 点光 | 严重 — 无法搭建复杂场景 |
| 锯齿明显 | TAA 管线存在但未启用 | 中等 |
| 纹理物体黑色 | bind group slot_offset 问题 | 致命 — 基础功能损坏 |

### 4.2 光栅管线目标状态

达到 **2022 年主流引擎** 画面品质：

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
- [ ] 审计 mesh_pass.zig bind group slot_offset 与 mesh.frag.glsl set=2 的对齐
- [ ] 验证所有 bind group 创建路径的 slot 正确性
- [ ] 场景中放置带贴图物体，确认不再渲染为黑色
- **验收**: TexturedCube 正确显示砖墙纹理

#### R-2 SSAO 接入光照
- [ ] mesh.frag.glsl 增加 `uniform sampler2D u_ssao_map` (新 binding)
- [ ] base_pass.zig 在 material bind group 中绑入 SSAO 纹理
- [ ] 着色器中: `ambient *= texture(u_ssao_map, screen_uv).r`
- **验收**: 角落/接缝处明显变暗，物体有接地感

#### R-3 级联阴影贴图 (CSM)
- [ ] ShadowMapState 从单张 2K 改为 4 级级联 (2K x 4 = 8K atlas 或 4 张 2K)
- [ ] 计算每级投影矩阵：基于视锥体分割 (practical split scheme)
- [ ] mesh.frag.glsl: 根据片元深度选择级联层级采样
- [ ] shadow_pass.zig: 4 次渲染（每级一次）
- **验收**: 近处阴影锐利，100m 外物体阴影仍清晰; render-test golden 更新

#### R-4 多光源支持
- [ ] BasePassUniforms 改用数组: `directional_lights[4]`, `point_lights[16]`, `spot_lights[8]`
- [ ] mesh.frag.glsl: 循环遍历活跃光源累加 radiance
- [ ] PreparedScene 收集场景中所有灯光，按距离/强度排序截断
- **验收**: 场景中放 4 盏点光，各区域被不同颜色照亮

#### R-5 TAA 完整接入
- [ ] 投影矩阵注入 Halton 2,3 序列 jitter (每帧不同)
- [ ] 历史纹理管理: ping-pong 双缓冲
- [ ] taa_pass.zig: reprojection + neighborhood clamp + history blend (alpha=0.1)
- [ ] 运动向量 Pass：静态场景可用 depth+VP 反推，动态场景需 velocity buffer
- [ ] 渲染顺序: 在 Tonemap 之前
- **验收**: 细线/围栏边缘无闪烁，移动相机时画面稳定

#### R-6 屏幕空间 GI (SSGI)
- [ ] 新 Pass: ssgi_pass.zig + ssgi.frag.glsl
- [ ] 从 depth buffer 重建世界坐标，在屏幕空间 trace 短距离光线
- [ ] 采样命中点的颜色作为间接光贡献
- [ ] 输出混合到 base pass ambient 项
- **验收**: 红墙旁的白物体有红色溢出; 角落有颜色反弹

#### R-7 SSR 粗糙度模糊
- [ ] SSR pass 输出 hit distance + screen UV
- [ ] 根据 roughness 对 SSR 结果做 cone tracing 模糊 (mip chain)
- [ ] 光滑表面清晰反射，粗糙表面模糊反射
- **验收**: roughness=0.0 镜面反射，roughness=0.5 模糊反射

#### R-8 Contact Shadows
- [ ] mesh.frag.glsl 中对每个片元沿光源方向做短距离 screen-space ray march
- [ ] 只检测前 0.5m，补充 CSM 在小尺度的细节
- **验收**: 石头放在地面上，底部有紧密的接触阴影

---

## 五、路径追踪渲染器 — 从 Demo 到生产品质

### 5.1 当前差距诊断

| 问题 | 根因 | 对比 Blender Cycles |
|------|------|-------------------|
| 4 SPP 纯噪声 | 均匀半球采样，无重要性采样 | Cycles: GGX IS, 同 SPP 噪声低 100x |
| 间接光极慢收敛 | 无 NEE（下一事件估计） | Cycles: 多光源直接采样 + MIS |
| 金属/玻璃不正确 | 假 Blinn-Phong，无 Fresnel | Cycles: Principled BSDF |
| 无降噪 | 原始输出 | Cycles: OIDN 32 SPP 约等于干净成品 |
| 天空假 | 线性渐变 | Cycles: HDR 环境贴图 / Nishita |
| 间接光偏暗 | 0.02 硬截止（有偏） | Cycles: 俄罗斯轮盘（无偏概率终止） |

### 5.2 路径追踪目标状态

达到 **32 SPP + OIDN = 干净影视画面**：

```
光线路径:
  Camera -> Surface Hit
    |- Direct Lighting (NEE): 随机采样光源 + shadow ray
    |- BRDF Sampling: GGX IS (specular) / cosine IS (diffuse)
    |- MIS: balance heuristic 组合 NEE + BRDF
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

### 5.3 逐项实施清单

#### PT-1 GGX 重要性采样
- [ ] 替换 `random_hemisphere()` 为 GGX 分布采样 (`sampleGGX_VNDF`)
- [ ] 漫射面用 cosine-weighted 半球采样
- [ ] 根据 metallic 概率选择 specular 或 diffuse lobe
- [ ] CPU 和 Metal kernel 同步修改
- **验收**: 4 SPP 金属球可辨认形状（当前是纯噪声）

#### PT-2 NEE + MIS
- [ ] 每次命中点额外采样一条 shadow ray 直连光源
- [ ] 光源采样 PDF: 方向光=delta, 面光源=面积采样
- [ ] BRDF 采样 PDF: GGX/cosine 对应值
- [ ] MIS balance heuristic: `w_light = pdfL^2 / (pdfL^2 + pdfB^2)`
- **验收**: 4 SPP 直接光照区域基本收敛

#### PT-3 Principled BSDF
- [ ] Schlick Fresnel: `F0 + (1-F0) * (1-cosTheta)^5`
- [ ] 金属: F0 = albedo; 电介质: F0 = 0.04
- [ ] Transmission lobe: Snell 折射 + 全内反射判断
- [ ] Roughness -> GGX alpha 映射: `alpha = roughness^2`
- [ ] 能量守恒: diffuse *= (1 - metallic) * (1 - F)
- **验收**: 玻璃球折射背景; 金属球正确反射环境

#### PT-4 HDR 环境贴图采样
- [ ] 支持 .hdr / .exr 天空纹理
- [ ] 环境光 NEE: 根据亮度分布做 importance sampling (alias method)
- [ ] 替换线性渐变 sky fallback
- **验收**: HDRI 照明下物体有真实环境反射

#### PT-5 俄罗斯轮盘 (无偏终止)
- [ ] 替换 `if (length(throughput) < 0.02) break` 为概率终止:
  `survival_prob = min(max_component(throughput), 0.95); if (rand > survival_prob) break; throughput /= survival_prob;`
- [ ] CPU 和 Metal kernel 同步
- **验收**: 间接光不再系统性偏暗

#### PT-6 自适应采样
- [ ] 每个 tile (8x8) 追踪方差
- [ ] 高方差区域继续采样，低方差区域提前终止
- [ ] 全局 SPP budget 动态分配
- **验收**: 同等总采样数下，噪声分布更均匀

#### PT-7 OIDN 降噪器集成
- [ ] 集成 Intel Open Image Denoise (C API, 跨平台)
- [ ] 输出辅助 AOV: albedo buffer, normal buffer
- [ ] 32 SPP + OIDN = 干净成品
- [ ] Metal GPU 路径: 可选 MPS denoiser (Apple Silicon 加速)
- **验收**: 32 SPP 渲染后降噪无可见噪点

#### PT-8 EXR 序列帧输出
- [ ] 支持 OpenEXR 格式写入 (半精度 RGBA16F)
- [ ] Camera Animation 驱动帧序列渲染
- [ ] 输出路径: `renders/{scene}_{frame:04d}.exr`
- **验收**: 10 帧动画序列正确输出

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
- [ ] 所有 dock 窗口设置 `gui.setNextWindowSizeConstraints(min_w, min_h, FLT_MAX, FLT_MAX)`
  - Scene Hierarchy: min 220px
  - Inspector: min 260px
  - Asset Browser: min 200px
  - Viewport: min 400x300
- **验收**: 拖拽面板边，不会小于最小尺寸

#### UI-2 工具栏自适应断点
- [ ] 调整断点: Wide >= 680px, Medium >= 400px, Narrow < 400px
- [ ] 按钮宽度改用 `gui.calcTextSize(label)[0] + padding` 自动计算
- [ ] Medium 模式: 只保留图标 + tooltip
- [ ] Narrow 模式: 折叠到 hamburger 菜单
- **验收**: 600px viewport 宽度下工具栏完全可见

#### UI-3 状态栏平滑自适应
- [ ] 删除 1280px 硬编码跳变
- [ ] 使用比例分配: context 区 60%, metrics 区 40%, 根据内容截断
- [ ] 狭窄时隐藏低优先级指标 (内存/进程RSS)
- **验收**: 任意窗口宽度下状态栏内容可读

#### UI-4 Inspector 窄面板优雅降级
- [ ] panel 宽度 < 260px 时切换为 stacked 布局 (label 上 + value 下)
- [ ] 属性网格列宽比例自适应: `label_width = clamp(width * 0.34, 80, 160)`
- **验收**: Inspector 260px 时所有属性可编辑

#### UI-5 带纹理预设物体
- [ ] Place Actors 面板增加: "Textured Cube"、"Textured Sphere"、"Textured Plane"
- [ ] 点击后弹出文件选择对话框选择纹理
- [ ] 自动创建实体 + 材质实例 + 赋予纹理
- **验收**: 3 次点击将带纹理立方体放入场景

#### UI-6 拖拽纹理到 Inspector 材质字段
- [ ] Inspector 材质区域的 texture slot 支持拖拽 payload 接收
- [ ] Asset Browser 中纹理条目可拖出
- **验收**: 从 Asset Browser 拖拽 .png 到 Inspector 的 Base Color 区域完成赋值

---

## 七、3D 创作工具链 — 对标 Blender 基础能力

### 7.1 对标范围

| Blender 能力 | 对标 | 不做 |
|-------------|------|------|
| 3D 视口导航 | ✅ 已有 | -- |
| 物体变换/层级 | ✅ 已有 | -- |
| 材质编辑器 | ✅ 已有参数面板 | 节点着色器编辑器 (Phase 2) |
| 相机动画 | 需要 | -- |
| 渲染输出 (Cycles 品质) | 路径追踪重写后 | -- |
| UV 编辑 | 基础 UV 查看/编辑 | 高级 UV 展开算法 |
| 灯光系统 | 多光源 + 面光源 | IES 灯光 |
| 渲染设置面板 | ✅ 已有 | -- |
| Outliner (层级管理) | ✅ 已有 | -- |
| Properties Panel | ✅ 已有 | -- |
| Timeline (关键帧) | 需要 | 曲线编辑器 (Phase 2) |
| 渲染视图 / 材质预览 | 需要 | -- |
| 合成器 (Compositor) | 不做 | -- |
| 雕刻 / 绘制 | 不做 | -- |
| 流体/布料模拟 | 不做 | -- |
| 视频编辑 | 不做 | -- |
| 4K 图片/视频输出 | 需要 (FFmpeg 编码) | 专业后期彩色管理 |

### 7.2 创作工具实施清单

#### CT-1 节点式材质编辑器
- [ ] 节点系统: PBR 参数节点 -> 输出节点
- [ ] 内置节点: Texture Sample, Color, Float, Mix, Normal Map, Noise, Voronoi
- [ ] 实时预览球体
- [ ] 编译为 GLSL fragment shader (光栅) + path tracer eval 函数 (离线)
- **验收**: 用节点编辑器创建带有噪声纹理混合的材质, 光栅和路径追踪渲染一致

#### CT-2 关键帧动画系统
- [ ] 属性关键帧: 任意 float/vec3 属性可设置关键帧 (Transform, Light intensity, ...)
- [ ] 插值类型: 线性 / 贝塞尔 / 阶梯
- [ ] Timeline UI: 底部时间线面板，显示关键帧菱形标记
- [ ] 播放控制: Play / Pause / 帧步进 / 跳转
- **验收**: 创建 5 秒相机飞行动画，可以帧步进预览

#### CT-3 Camera Sequencer (相机切换器)
- [ ] 多相机: 场景中放置多个 Camera 实体
- [ ] 序列器: 时间线上分段标记使用哪个 Camera
- [ ] 渲染输出: 按序列器定义的相机顺序渲染帧序列
- **验收**: 两个相机在 3 秒处切换，渲染输出正确

#### CT-4 面光源 (Area Light)
- [ ] 新光源类型: Rectangle / Disk
- [ ] 光栅: 近似为点光 + soft shadow
- [ ] 路径追踪: 真正面光源采样 (NEE)
- **验收**: 面光源在路径追踪模式下产生物理正确的软阴影

#### CT-5 基础 UV 编辑器
- [ ] 2D UV 视图面板 (新 editor window)
- [ ] 显示当前选中 mesh 的 UV 展开
- [ ] 支持选择 UV 顶点/边/面，基础平移缩放
- [ ] 自动 UV 投影: Box / Planar / Cylindrical
- **验收**: 查看 glTF 导入模型的 UV，调整后纹理映射更新

#### CT-6 渲染输出面板
- [ ] 输出设置: 分辨率预设 (1080p / 2K / 4K) + 自定义分辨率 / 帧范围 / 输出格式 (PNG / EXR) / 输出路径
- [ ] 采样设置: SPP / 降噪开关 / 自适应采样
- [ ] 一键渲染: "Render Image" / "Render Animation" / "Render Video"
- [ ] 进度显示: 当前帧/总帧 + 累积 SPP + 预计剩余时间
- [ ] 4K 支持: 3840x2160 渲染，分 tile 渲染避免显存溢出 (每 tile 512x512)
- **验收**: 设置 3840x2160 (4K), 128 SPP, 渲染单帧输出 EXR，文件大小 ~60MB

#### CT-7 视频编码输出 (FFmpeg)

引擎不做视频编辑器，但必须能将渲染帧序列编码为标准视频格式。策略：渲染器输出帧序列 -> FFmpeg 子进程编码 -> 输出 MP4/MOV。

- [ ] FFmpeg 子进程调用封装 (不链接 libav，仅调用 ffmpeg CLI)
- [ ] 支持编码格式: H.264 (兼容性最佳) / H.265 (4K 体积减半) / ProRes (影视后期交换)
- [ ] 渲染流水线: Path Tracer 渲染帧 -> EXR 暂存 -> OIDN 降噪 -> Tonemap -> FFmpeg 编码
- [ ] 音频混合: 场景 AudioSource 混音轨道合并到视频 (SoLoud -> WAV -> FFmpeg mux)
- [ ] 输出预设:
  - **Web**: 1080p H.264 CRF18, 30fps
  - **4K Cinema**: 3840x2160 H.265 CRF15, 24fps
  - **Post-Production**: 4K ProRes 422, 24fps (供 DaVinci/Premiere 后期)
- [ ] 编辑器 UI: 渲染输出面板增加 "输出格式" 下拉 + 编码质量滑块
- **验收**: 10 秒相机动画 -> 一键渲染 -> 输出 4K H.265 MP4 视频文件，可在播放器中流畅播放

---

## 八、游戏运行时系统

### 8.1 逐项清单

#### GR-1 音频系统修复与完善
- [ ] 修复 SoLoud 初始化错误
- [ ] AudioSource / AudioListener / AudioClip 组件
- [ ] 3D 空间音效: 距离衰减、Voice group
- [ ] Inspector 编辑: 音量 / 循环 / 3D 设置
- **验收**: 实体附加 AudioSource，播放时声音随距离衰减

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

#### GR-4 Physics WASM API
- [ ] Raycast: `physics.raycast(origin, direction, maxDist) -> HitInfo`
- [ ] OverlapSphere / OverlapAABB
- [ ] TriggerEnter / TriggerExit 回调到 WASM 脚本
- **验收**: WASM 脚本发射射线检测碰撞，返回碰撞实体 ID

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
- [ ] WASM 绑定: `ui.createButton("Start")` / `ui.setText(id, "HP: 100")`
- **验收**: 屏幕上方显示血条，血量变化时进度条更新

#### GR-8 多语言脚本前端 (Python / C#)

当前 ScriptVM 已支持 Zig 和 WASM。WASM 是语言无关的字节码层，任何能编译到 WASM 的语言都可以接入，无需嵌入独立解释器/运行时，性能由 WAMR JIT 保证。

| 语言 | 编译路径 | 适用场景 |
|------|---------|----------|
| **Zig** | 直接编译到 WASM (已有) | 高性能游戏逻辑、引擎插件 |
| **Python** | MicroPython -> WASM (wasm32-wasi) | AI 生成脚本、快速原型、工具脚本 |
| **C#** | .NET NativeAOT -> WASM 或 Mono WASM | 传统游戏开发者、Unity 迁移用户 |

**为什么优先 Python**：AI (LLM) 生成 Python 代码的准确率远高于其他语言，且 Python 语法简洁适合非程序员。通过 MicroPython→WASM 路径，脚本运行在 WAMR 沙盒中，性能接近原生 WASM（比 CPython 解释器快 10-50x），同时保持热重载和 Inspector 反射。

实施清单:
- [ ] MicroPython 交叉编译到 wasm32-wasi 目标
- [ ] ScriptVM 增加 Python 前端: `.py` 文件 -> MicroPython WASM 模块
- [ ] Python 绑定层: 自动生成 `engine.*` / `physics.*` / `ui.*` Python API wrapper
- [ ] Python Inspector 反射: 解析模块级变量类型标注，暴露到 Inspector
- [ ] AI 工作流: Jarvis 生成 `.py` 脚本 -> 自动编译 -> 热重载 -> 运行验证
- [ ] (可选) C# 前端: .NET NativeAOT WASM 编译 + C# API 绑定
- **验收**: AI 生成一段 Python 巡逻脚本，引擎热重载后 NPC 自动巡逻; Inspector 显示 Python 脚本的 `patrol_speed: float = 3.0` 参数

---

## 九、AI-Native 基础设施

### 9.1 已完成

| 能力 | 状态 |
|------|------|
| MCP stdio 协议 | ✅ |
| 只读场景/实体/选择感知 | ✅ |
| CommandQueue 统一写入 | ✅ |
| Staged Transaction + Ghost Preview | ✅ |
| Query API (语义/空间/BVH) | ✅ |
| Schema 资源族 | ✅ |
| WASM 脚本 + Inspector 反射 | ✅ |
| Editor Utility UI (35 ImGui API) | ✅ |

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

---

## 十、分阶段执行路线图

### Phase 1：修复基础 — 让看得见的东西先正确

> 前置: 无

| ID | 任务 | 检验标准 |
|----|------|---------|
| R-1 | 修复纹理绑定 slot_offset | TexturedCube 显示纹理 |
| R-2 | SSAO 接入光照着色器 | 角落变暗有接地感 |
| UI-1 | 面板最小尺寸约束 | 拖窄不再失效 |
| UI-2 | 工具栏断点下调 | 600px 宽仍可用 |
| GR-1 | 音频初始化修复 | SoLoud 不报错 |

### Phase 2：现代光栅管线

> 前置: Phase 1

| ID | 任务 | 检验标准 |
|----|------|---------|
| R-3 | 级联阴影 (4-CSM) | 远处阴影清晰 |
| R-4 | 多光源 (dir x4 + point x16) | 4 盏点光照亮不同区域 |
| R-5 | TAA 完整接入 | 围栏边缘无闪烁 |
| R-6 | SSGI | 红墙旁白物体有红色溢出 |
| R-8 | Contact Shadows | 物体底部有接触阴影 |

### Phase 3：RHI 重构 — Metal 原生 Backend

> 前置: Phase 2 (光栅管线稳定后再换底层)

| ID | 任务 | 检验标准 |
|----|------|---------|
| RHI-1 | Metal Graphics Backend | 18 个 Pass 在新 RHI 上渲染一致 |
| RHI-2 | Metal Compute Backend | IBL 改 GPU 计算，SSAO dispatch |
| RHI-3 | Metal RT 统一到 RHI | RT Shadow 和 Path Trace 走统一接口 |

### Phase 4：路径追踪器重写

> 前置: RHI-2 (Compute)

| ID | 任务 | 检验标准 |
|----|------|---------|
| PT-1 | GGX 重要性采样 | 4 SPP 金属球可辨认 |
| PT-2 | NEE + MIS | 直接光 4 SPP 基本收敛 |
| PT-3 | Principled BSDF | 玻璃球折射正确 |
| PT-4 | HDR 环境贴图 | HDRI 照明下物体有环境反射 |
| PT-5 | 俄罗斯轮盘 | 间接光亮度不再偏暗 |
| PT-7 | OIDN 降噪 | 32 SPP + 降噪 = 干净画面 |

### Phase 5：创作工具链

> 前置: Phase 2 (多光源), Phase 4 (PT)

| ID | 任务 | 检验标准 |
|----|------|---------|
| CT-2 | 关键帧动画 + Timeline | 5 秒相机飞行动画 |
| CT-3 | Camera Sequencer | 多相机切换渲染 |
| CT-4 | 面光源 | PT 模式下物理正确软阴影 |
| CT-6 | 渲染输出面板 (含 4K) | 一键渲染 4K EXR |
| CT-7 | FFmpeg 视频编码 | 4K H.265 MP4 输出 |
| PT-8 | EXR 序列帧输出 | 10 帧动画序列正确输出 |

### Phase 6：游戏运行时补全

> 可与 Phase 5 并行

| ID | 任务 | 检验标准 |
|----|------|---------|
| GR-2 | 多场景管理 | 跨场景保留玩家数据 |
| GR-3 | GameState (Play/Stop) | Stop 后场景恢复 |
| GR-4 | Physics WASM API | 脚本中 raycast 工作 |
| GR-5 | 导航寻路 | Agent 自动避障 |
| GR-6 | 输入映射 | 键盘+手柄映射同一 action |
| GR-7 | 游戏内 UI | 血条随数值变化 |
| GR-8 | Python 脚本前端 | AI 生成 .py 脚本热重载运行 |

### Phase 7：跨平台 + 创作工具扩展

> 前置: Phase 3

| ID | 任务 | 检验标准 |
|----|------|---------|
| RHI-4 | Vulkan Graphics Backend | Linux/Windows 下渲染一致 |
| RHI-5 | Vulkan Compute + RT | Vulkan RT 阴影工作 |
| CT-1 | 节点材质编辑器 | 噪声混合材质可编辑 |
| CT-5 | UV 编辑器 | 查看/调整 UV 映射 |
| PT-6 | 自适应采样 | 渲染时间减半 |
| R-7 | SSR 粗糙度模糊 | 粗糙表面模糊反射 |

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
- [ ] render-test 8 配置全部 PASS
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
| `ScriptVM` | 脚本运行时抽象层 (WasmVM / ZigVM) |
| Principled BSDF | 统一材质模型（对标 Blender / Disney） |
