# Guava Engine 架构设计

Guava Engine 的目标不是“只做游戏引擎”，而是做一个覆盖实时游戏、影视动画预览、DCC 工具、虚拟制片预演以及离线工作流前端的通用引擎。



- `src/engine/core`
  应用生命周期、Layer 抽象、平台识别。
- `src/engine/platform`
  SDL3 窗口和事件循环，相当于一个轻量的 `DisplayServer` 起点。
- `src/engine/render`
  Renderer、RenderGraph、共享场景缓存和显式 pass，负责把世界快照变成一组明确的渲染阶段。
- `src/engine/rhi`
  明确的资源层，负责 `Device / Buffer / Texture / TransferBuffer / CommandBuffer / Swapchain`。
- `src/engine/assets`
  资源库、shader 生成、glTF 静态导入和后续 DCC/影视资产接入的起点。
- `src/engine/scene`
  兼容层，当前把 `Scene` 映射到 `World`。
- `src/engine/scene/world.zig`
  明确的 `World / Entity / Asset` 运行边界，当前实体和资源都从这里进入渲染。

## 当前已经打通的真实闭环

统一到了 `Guava RHI -> SDL3 GPU` 这一层：

1. `SDL3` 创建高 DPI 窗口。
2. `Guava RHI` 按后端顺序尝试创建设备。
3. 当前设备实现来自 `SDL3 GPU`，它原生承接 `Metal / Vulkan / D3D12`。
4. RHI 负责创建 depth texture、获取 swapchain texture、申请 command buffer、开启 render pass、clear、present。
5. 上层 `Renderer` 只编排 RenderGraph 和场景快照，不再直接持有某个 API 的专属对象。
6. 当前 Vulkan 和 Metal 路径都已经补齐 `ShaderModule / GraphicsPipeline / Sampler / BindGroup / VertexBuffer / IndexBuffer / Texture Upload`，并打通了一个真实的 mesh 绘制闭环。

现在 `zig build run` 会真实打开窗口，并输出：

- 当前图形后端
- 当前图形设备名
- 当前 RHI driver 名
- 当前 drawable 尺寸
- depth buffer 是否已就绪
- 当前 draw call 数和三角形提交数

## 当前后端策略

- 默认显式顺序：`Vulkan -> DX12 -> Metal`
- macOS / iOS 当前实际回退：`Vulkan(MoltenVK) -> Metal`
- Windows 目标顺序：`Vulkan -> DX12`
- Linux / Android 目标顺序：`Vulkan`

这个顺序是故意的。Guava Engine 作为通用引擎，需要优先保证跨平台资源模型一致，而不是每个平台都先走最原生但最分裂的 API。

当前的“先接 Vulkan，再接 DX12”并不是写两套完全重复的引擎代码，而是先把 `RHI` 资源模型定稳，再让 SDL3 GPU 的 `vulkan` 和 `direct3d12` driver 成为第一阶段可运行后端。后续如果要把 Vulkan/DX12 下探成自研后端，也可以保持同一套 RHI 资源接口不变。


## 当前运行边界

现在主路径是：

`Application -> World -> Window -> Renderer -> MeshSceneCache -> IDPass -> DepthPrepass -> BasePass -> OutlinePass -> RHI Device`

- `Application` 管生命周期、Layer、主循环。
- `World` 管实体、资源和资产导入，是游戏运行时、影视预览和工具链共享的数据边界。
- `Window` 只管 SDL3 窗口和平台事件。
- `Renderer` 管 RenderGraph、场景快照、选中对象和每帧提交顺序。
- `MeshSceneCache` 管 `MeshResource / MaterialResource / TextureResource` 到 GPU 资源的上传与缓存。
- `IDPass` 负责把可见实体编码到离屏 ID 纹理，为编辑器选择和后续 readback 打基础。
- `SelectionReadback` 在鼠标点击时把 ID 纹理的 1x1 像素同步读回 CPU，并解码成当前选中实体。
- `DepthPrepass` 先建立深度，给后续基础材质和编辑器辅助 pass 复用。
- `BasePass` 负责当前最小 mesh/material 提交路径。
- `OutlinePass` 负责基于 ID 纹理做最终轮廓高亮合成。
- `RHI` 管 GPU 设备、资源、swapchain、command buffer 和 render pass。

这意味着旧的 `RenderingServer` 中间层已经从运行路径移除。对 Layer 而言，如果需要直接申请 GPU 资源，拿到的是 `LayerContext.rhi()`；如果需要访问世界数据，拿到的是 `LayerContext.world`。

## 当前资产与 shader 管线

- `build.zig` 会在编译前运行 `tools/shader_codegen.zig`。
- shader 源文件目前集中在 `assets/shaders`，先编译成 SPIR-V，再用 `spirv-cross` 生成 reflection 元数据和 MSL 代码。
- 生成产物写入 `src/engine/generated/shaders.zig`，运行时按后端选择 `SPIR-V` 或 `MSL` 变体。
- `World.resources` 现在持有明确的 `MeshResource / MaterialResource / TextureResource`，渲染层不再依赖硬编码几何体。
- `glTF 2.0` 静态导入已经接进 `World.importGltfStaticModel()`，当前覆盖网格、节点层级、TRS、顶点色、UV、normal、tangent、多个 primitive/material 和 `baseColorTexture` 的 PNG/JPEG 解码。

## 为什么这更适合影视动画

- 游戏运行时和影视预览都需要同一套世界数据、材质和摄像机系统。
- DCC/编辑器工具更需要稳定的资源生命周期和可重放的命令提交，而不是临时拼接 draw call。
- 离线工作流前端同样需要 RenderGraph、资源编排和明确的后端边界，只是调度目标会从“实时帧”扩到“镜头/批任务”。
- 当资源层明确下来之后，后面接资产系统、缓存系统、序列化、渲染农场前端，成本会比“纯游戏引擎再硬改”低得多。

## 当前实时几何通路

- 当前主 shader 是 `assets/shaders/mesh.vert.glsl` 和 `assets/shaders/mesh.frag.glsl`。
- `DepthPrepass`、`IDPass` 和 `OutlinePass` 也已经各自拥有独立 shader 入口，并统一纳入 `build.zig -> shader_codegen` 自动生成链。
- Vertex shader 使用一个矩阵 uniform 块，负责 `view_projection / model`。
- Fragment shader 使用一个材质 uniform 块和一个 `base_color` 采样器。
- `MeshSceneCache` 会遍历世界资源，把 `MeshResource / MaterialResource / TextureResource` 上传成 GPU 资源并缓存。
- 默认示例场景会同时画内建 plane/cube 和一个导入的 textured glTF showcase。
- 当前真实提交顺序是 `IDPass -> DepthPrepass -> BasePass -> OutlinePass`。
- 鼠标左键点击窗口时，`Renderer` 会请求一次 `SelectionReadback`，把 ID 纹理的点击像素读回并更新当前选中实体。
- 这条路径已经在 `Vulkan` 和 `Metal` 上验证通过，证明 SDL3 GPU 背后的两个 driver 都不只是“能开窗 clear”，而是能稳定创建 pipeline、上传 buffer/texture、绑定资源并提交 draw。

## 下一阶段建议

优先级建议如下：

1. 把 shader 生成继续扩到 `DXIL`
   这样 `DX12` 路径才能进入真实 draw 验证。
2. 把当前 pass 继续扩到 `ShadowPass / GizmoPass / EditorComposite / SelectionHistory`
   这样编辑器、镜头工作流和影视预演会更完整。
3. 把 glTF 导入继续扩到 skinning、animation、morph target 和更完整的 PBR 贴图集
   这样才能真正接近角色动画和影视资产。
4. 再往上做编辑器和 DCC/影视工具链接口


## 推荐原则

- Core 层不依赖具体图形 API。
- Platform 层只负责窗口、输入、系统事件。
- Renderer 负责编排场景与渲染阶段，RHI 只关心 GPU 能力、资源生命周期和提交。
- World/Scene 层只产出渲染世界数据，不直接发 draw call。
- 游戏、影视动画、工具链三类需求应该在同一套世界数据和资源层上汇合，而不是分裂成三套引擎。
