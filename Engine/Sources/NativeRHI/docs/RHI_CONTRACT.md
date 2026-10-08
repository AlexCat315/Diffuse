# NativeRHI 内部契约

`NativeRHI` 是 Guava 自有的显式 GPU 接口。前端负责句柄、布局、命令记录、帧生命周期和提交规划；后端负责原生对象与执行。资源和布局的组织可参考 WebGPU，但高级能力独立设计，不承诺符合 WebGPU 标准。

这一轮参考了本地 NRI、NVRHI 和 slang-rhi 源码中的布局、原生管线和资源生命周期组织，保持自有接口与实现，不引入这些项目的运行时依赖。Slang 只承担离线编译；RHI 接收目标产物，其他编译器也可以生成相同的 `ShaderArtifact`。

现有 renderer 默认仍使用 `RHIWGPU`。`RenderBackend.NativeEditorGridPass` 和 `NativeGridRenderer` 已接入 NativeRHI，复用真实 RenderPacket、相机和网格参数；EngineHost 可通过 `renderConsumer` 注入该独立 consumer。接入、画面与性能记录见 [网格 pass 验证](NATIVE_GRID_VALIDATION.md)。NativeRenderer 也已迁移静态场景的深度和不透明/遮罩几何 pass，资源重载与实例化通过本机验证，详见 [场景迁移验证](NATIVE_SCENE_VALIDATION.md)。PBR、级联/多光源阴影、HDR 天空与 tonemap 已接入，见 [PBR 验证](NATIVE_PBR_VALIDATION.md)。透明/蒙皮/变形网格、r5 post/history/cache、风格化及 CPU 粒子绘制也已通过本机对照。resident GPU 粒子物理与事件迁移见 [模拟验证](NATIVE_PARTICLE_SIMULATION_VALIDATION.md)；GPU 排序/实例转换与 UI 互操作仍待迁移。

Clip space 使用 +Y 向上、深度 0…1；framebuffer / viewport 使用左上原点、+Y 向下。Vulkan backend 通过负高度 viewport 统一这一约定，shader 不再自行翻转 Y。

## 实现与验证状态

| 路径 | Metal | Vulkan | DX12 |
| --- | --- | --- | --- |
| Buffer / Texture / Sampler、上传与读回 | 本机验证 | Windows/Linux 原生实现，待验证 | 原生实现，Windows 待验证 |
| Raster / Compute、绑定、indirect、copy | 本机验证核心路径 | Windows/Linux 原生实现，待验证 | 原生实现，Windows 待验证 |
| 窗口呈现与 resize | 本机验证 | Win32 / Xlib / Wayland 原生实现，待验证 | HWND swapchain 实现，待验证 |
| 帧上传、延迟销毁、跨队列同步 | 本机验证 | 原生实现，独立 queue family 待验证 | 原生实现，待验证 |
| Mesh / task | Mesh 已验证；task 关闭 | EXT 管线与直接 dispatch 实现，设备功能链控制，GPU 待验证 | MS / AS 管线与直接 dispatch 实现，GPU 待验证 |
| BLAS / TLAS / compute ray query | 原生 MSL 命中与未命中已验证 | KHR 构建、地址、绑定实现，GPU 待验证 | DXR 构建、绑定实现；inline query 要求 tier 1.1，GPU 待验证 |
| RT pipeline / SBT、AS update / compaction、间接 mesh | 关闭 | 关闭 | 关闭 |

`Device.capabilities` 表示实现路径与当前设备支持的交集，默认值全部关闭。**功能存在与平台验证是两件事**：DX12、Vulkan RT / mesh 的源码已接入，但本机没有相应设备，不能把它们称为已验证。

`adapterCapabilities` 是硬件诊断信息，不能代替 `capabilities`。光追能力表示 API 可用，不保证具有专用光追单元；本机 Apple M1 测试验证功能正确性，不代表专用 RT 硬件性能。

## 布局与 shader ABI

- 先创建 binding layout 和 pipeline layout，再创建管线；具体 binding set 可以晚于管线创建。后端不能通过现存 binding set 推断管线布局。
- Binding layout 声明 slot、资源类型、`ShaderVisibility` 和 buffer 访问/结构信息。一个资源可同时供 vertex 与 fragment 使用。Binding set 必须覆盖全部声明，资源类型匹配；目前不支持数组、bindless。
- Uniform binding 可声明 `size`，nil 表示 buffer 剩余范围。帧上传的大 buffer 绑定小常量块时应提供实际字节数，以满足 Vulkan `maxUniformBufferRange`；范围也参与 binding-set 缓存 key。帧上传 buffer 声明 uniform、storage read、vertex/index/indirect 与 copy 用途。
- `BufferBindingLayout.readOnly` 决定 SRV / UAV 和读写依赖；`elementStride` 保存离线反射的 structured buffer 元素大小，零表示 byte-address。不要把只读 storage buffer 当作 UAV。
- Pipeline layout 缓存按有序 set layouts 与 push constant 声明共同建 key。资源绑定和小常量会在提交前检查是否匹配当前管线。
- `PushConstantRange` 声明 stage、逻辑 slot、字节数。slot 和 stage 分别唯一；每个 stage 最多一个块，整个布局最多 128 字节，大小须为四字节倍数。Metal 使用 buffer 参数；DX12 使用 space0 的 b-register root constants；Vulkan 每个 stage 的 SPIR-V push block 从 offset 0 开始，以不同 stage mask 允许范围重叠。
- Slang fixture 使用显式 register / Vulkan binding，目标反射决定实际 slot。工具拒绝目标 slot 冲突，不猜测跨后端 register 映射。
- Metal 当前直接绑定 set 0；buffer slot 24...31 留给 vertex inputs。Vulkan 和 DX12 支持多个 set；DX12 set index 对应 register space。DX12 root signature 仍受原生 64 DWORD 限制。
- `VertexAttribute.semantic` 保存 DXIL input semantic，默认 TEXCOORD + location。使用 POSITION 等 HLSL 语义时，调用方应显式配置；Metal / Vulkan 使用 location。

当前 graphics 不支持 stencil pipeline state；纹理采用单采样。Depth、MRT、blend、raster、vertex/index 和直接/间接 draw 使用各自的原生描述。

## 资源与帧生命周期

句柄属于创建它的设备，ID 不复用；不要伪造 ID。`destroy` 后不能再录制使用该资源，也不能复用引用它的 binding set。后端对象延迟到调用时全部在途帧结束后，在 API 线程上销毁；completion 线程只记录完成和错误。

```swift
try device.beginFrame()
let image = try device.acquireSwapchainImage() // 窗口渲染时
try device.submit(commands, queue: .graphics)
try device.present(image)
device.endFrame()
try device.waitUntilIdle() // 调试、测试或停机
```

一个设备同时只有一个活动帧。每帧可提交多个 command buffer；帧须已封闭且全部提交完成，上传内存和 command pool 才能复用。帧上传使用 `uploadTransient`；创建或重置失败会抛错，不以 force unwrap 崩溃。

规划器跟踪状态、访问依赖与 queue ownership，跨 queue 用 timeline handoff。多个 queue class 不代表多条独立硬件队列。Vulkan 资源跨不同 queue family 采用 concurrent sharing，各 family 使用独立 command pool。提交路径采用异步 fence completion，不调用 queue idle。

立即上传会同步完成，并登记 transfer write，供下次提交生成依赖。修改已有资源时，调用方须先保证没有 GPU 同时访问该范围。立即纹理传输适合初始化与调试；上传/读回通过 TextureSubresource 指定 mip/layer，默认 mip0、第一层。`readBufferData` 必须在 endFrame 后使用，等待此前 GPU 工作完成后回读指定字节范围；Metal 读取 shared buffer，Vulkan 使用 coherent staging 与 transfer/host barrier，DX12 使用 READBACK heap 与 CopyBufferRegion。读回不改变 planner 的写入版本。正常帧的颜色纹理 copy 命令当前仅访问 mip0、第一层；行距使用字节。DX12 通过临时缓冲重排行距，适配原生 256 字节 row pitch。

规划或录制失败且尚未排入 GPU 的工作会回滚状态和 timeline。一次前端提交若已有部分工作排队后失败，设备阻止继续提交，须重建，避免错误复用状态。GPU completion 错误在 `waitUntilIdle` 上抛出。

Vulkan acquire semaphore 由第一次 graphics submission 消费；present 使用每个 image 独立的二进制 semaphore，并保留最终 layout transition 的 command pool 到 fence 完成。Resize 会等待原生设备空闲并重建 image views。

## Shader 工具链

`ShaderArtifact` 包含 stage、格式、entry point、code、编译器标识，以及 local workgroup size、目标绑定、push constant ranges。RHI 不加载 Slang runtime 或 reflection 类型。

- Metal：MSL source / metallib。
- Vulkan：SPIR-V，保留实际 entry point 名称；要求 Vulkan 1.3 dynamic rendering 与 timeline semaphore。
- DX12：DXIL，当前工具使用 shader model 6.6，后端检查相同要求。编译需要 DXC/dxcompiler；本机没有该依赖，DXIL 产物未验证。

`scripts/compile-rhi-shader.py` 固定 Slang **2026.19**。编译器通过 `--slangc` 或 `SLANGC` 显式提供；编译时不下载。目标反射与 SPIR-V 逻辑反射用于区分普通资源和 push constant，原始目标 reflection 保留供检查。编译/反射失败不会覆盖已有产物。`ShaderInterface` 直接序列化 typed specialization constants 和工作组维度对应的 constant ID；Metal function constants 与 Vulkan VkSpecializationInfo 共用同一类型/值输入，物理 dispatch 和 LocalSizeId 一致。Vulkan 设备必须启用 maintenance4 才能使用 LocalSizeId。DXIL 不能运行时改 numthreads，粒子工具链在 Windows 编译完整的 1–256 离线代码族，Native loader 按工作组大小选择；缺失变体会明确失败。

`dispatch(groupsX:groupsY:groupsZ:)` 和 `drawMeshTasks` 的单位都是 workgroup 数量。local size 来自 shader module，例如 local size `(8,1,1)` 配合两个 groups 执行 16 个线程。当前 Slang mesh/task JSON 缺少 local size，必须显式传 `--threadgroup-size`，与 `numthreads` 一致。

Metal 光追仍使用原生 MSL；Slang Metal RT 和 Metal Shader Converter 不是已完成的依赖。

## 安装与本机验证

macOS arm64：

```sh
python3 scripts/bootstrap-rhi-slang.py
export SLANGC="$PWD/Engine/vendor/slang/bin/slangc"
swift test --package-path Engine --filter 'NativeRHITests\.' --jobs 4
python3 scripts/test-rhi-shader-toolchain.py
python3 scripts/check-swift-maintainability.py
```

macOS 只使用 Metal，不链接 Vulkan loader，不加载 Vulkan ICD，也不执行 Vulkan GPU 测试。Slang 是离线工具，产物无需运行时编译器。

Windows / Linux 使用安装的 Vulkan SDK，非系统位置设置 `VULKAN_SDK`。可在对应宿主上运行 `scripts/bootstrap-rhi-vulkan.py`，校验固定 Vulkan-Headers / Loader **1.4.328** 的 SHA-256 并安装到忽略的 `Engine/vendor/vulkan-sdk`；脚本在 macOS 明确拒绝运行。Windows 还需 Windows SDK 的 D3D12 / DXGI；DXIL shader 编译需 DXC。

`SurfaceDescriptor.kind` 区分 CAMetalLayer、HWND、Xlib Window 和 Wayland wl_surface。Xlib/Wayland 使用 `display`；Xlib 的 `nativeHandle` 保存 Window 的 pointer bit pattern。Vulkan 仅启用宿主实际提供的 WSI 扩展，并从已创建的 instance 解析 instance dispatch 命令。Surface 创建失败会释放对象；swapchain 检查 graphics queue 的呈现支持、请求的颜色格式和原生 drawable extent。仅有其他 queue family 支持呈现时，当前会明确拒绝该 surface。

这部分按本地 NRI/NVRHI/slang-rhi 的 dispatch/生命周期组织和 [Khronos instance dispatch](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetInstanceProcAddr.html)、[Wayland surface](https://docs.vulkan.org/refpages/latest/refpages/source/VkWaylandSurfaceCreateInfoKHR.html)、[swapchain 约束](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html)实现。Windows/Linux 源码本轮未做编译或 GPU 验证，不能将 macOS Metal 的结果推断到这两个平台。

本机 GPU 检查覆盖 Metal raster、多 stage uniform、compute、storage、纹理/sampler、mip/array 上传与 float readback、push constants、跨 queue copy/compute、窗口 present/resize、mesh 与 BLAS/TLAS ray query。失败录制和 planner checkpoint 有回归测试。缺少 GPU 或 `SLANGC` 时明确 skip；skip 不是通过证据。

## Mesh 与 AS 范围

Mesh 使用独立 descriptor。Metal 当前无 task；Vulkan 与 DX12 task 根据设备支持启用。间接 mesh dispatch 仍关闭。

BLAS 当前只支持不透明、非索引 float32 xyz 三角形。TLAS 引用已创建的 BLAS，变换为三个 SIMD4 行，默认单位矩阵，mask 默认 0xff。创建分配对象；先 `recordBuild(blas)`，再 `recordBuild(tlas)`，随后执行 compute ray query。RT pipelines、SBT、procedural geometry、AS update 与 compaction 尚未实现。

编辑器网格、静态场景深度/不透明几何 pass 已接入 NativeRHI。接下来迁移其他后处理、透明网格、粒子/动画和编辑器 UI 互操作，验证后切换默认 renderer；原生 Windows / Linux 环境可用后，再验证 DX12 与 Vulkan RT / mesh、独立 queue family。
