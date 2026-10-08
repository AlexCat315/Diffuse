# NativeRHI 内部契约

`NativeRHI` 是 Guava 自有的显式 GPU 接口。资源描述、命令记录和提交规划由前端负责，Metal / Vulkan / DX12 后端负责原生对象与执行。接口可参考 WebGPU 的资源与布局组织，但高级功能按原生 API 的能力设计；不承诺符合 WebGPU 标准。

这是第一阶段实现。目前包集成与 GPU 测试针对 Swift 6.4、macOS 13+、arm64。窗口、输入和 SDL 不属于本模块。现有 `RenderBackend` 仍使用 `RHIWGPU`，尚未迁移到 `NativeRHI`。

## 实现状态

| 路径 | Metal | Vulkan | DX12 |
| --- | --- | --- | --- |
| Buffer / Texture 创建和直接上传、读回 | 已实现并验证 | 已验证上传和纹理读回 | 源码骨架 |
| 命令记录、帧槽、延迟销毁、提交规划 | 已实现并验证 | Buffer copy 提交可用 | 不可用 |
| Raster / Compute pipeline | 可用；compute 已验证 Slang 输出 | 原型未完成，公开接口拒绝调用 | 不可用 |
| Mesh shader | 支持设备上可用，已验证 Slang 三角形 | 不可用 | 不可用 |
| Task / amplification shader、间接 mesh dispatch | 不可用 | 不可用 | 不可用 |
| BLAS / TLAS 与 compute ray query | 支持设备上可用，已验证原生 MSL 命中与未命中 | 不可用 | 不可用 |
| RT pipeline / SBT / AS update / compaction | 不可用 | 不可用 | 不可用 |

`Device.capabilities` 表示**当前后端已经实现，并且当前设备支持**的操作。所有默认值为关闭。高级功能需要独立检查，例如 `rayTracing.computeRayQuery` 与 `rayTracing.pipelines` 分别表示不同路径。

`Device.adapterCapabilities` 仅提供诊断信息。Vulkan 扩展存在或 DX12 feature query 返回支持，不能使尚未实现的命令可用。未知、不完整或未经验证的路径必须抛出 `unsupportedFeature`，不能静默忽略。

光追 capability 表示原生 API 可用，不保证 GPU 具有专用光追单元。本阶段在 Apple M1 上验证 API 正确性；具有专用光追硬件的设备仍需要另外验证性能。

Vulkan 当前只开放 graphics queue 上的 Buffer copy 命令；render / compute、录制的 texture copy 命令在提交规划前拒绝。同步使用保守的 buffer memory barrier。Vulkan 包接入仍依赖 Darwin loader；Windows / Linux 构建与原生 Vulkan RT、mesh 需要后续工作。DX12 在本机不能构建或验证。

## 资源与所有权

- `Device` 分配不透明句柄，ID 0 无效，ID 不复用。句柄只属于创建它的设备；不得自行伪造 ID。
- 后端注册表持有原生资源。调用 `destroy` 后，调用方不得再次使用该句柄，也不得复用引用它的 binding set 或命令。
- `destroy` 延迟到调用时所有在途帧都完成后，再在 Device API 线程上清理注册表；GPU completion 线程只更新完成状态。
- Binding layout 声明槽位、类型与 shader stage；binding set 必须恰好覆盖 layout，资源类型必须匹配。当前不支持 binding array。
- 空 binding layout / pipeline layout 合法，用于无资源 shader。布局缓存和 binding set 缓存由前端管理。
- 当前 Metal 采用直接绑定，仅支持 set 0。资源槽位使用目标产物的反射索引；buffer 参数槽 24...31 保留给最多八个 vertex buffer。多 set、argument buffer、bindless 与跨目标槽位映射不在本阶段。
- 直接 buffer 上传是 CPU 写入共享内存；调用方须保证没有 GPU 同时访问该范围。直接 texture 上传和读回会同步等待，适用于初始化、调试和测试；正常帧中的数据传输使用 copy 命令和 transient upload。

## 帧与提交

```swift
try device.beginFrame()
try device.submit(commands, queue: .graphics)
device.endFrame()
try device.waitUntilIdle() // 测试或停机时；正常帧不需要
```

一个设备同时只能有一个活动帧。`submit`、`uploadTransient` 需要活动帧。每帧可提交多个 command buffer；`endFrame` 封闭帧，只有封闭且所有提交完成后，帧槽才能复用。即使 GPU 在 `endFrame` 前完成，也不能提前重置上传内存或销毁资源。

`beginFrame` 仅在选中的帧槽仍在执行时等待。`waitUntilIdle` 需要先结束活动帧，并清理已经安全的延迟销毁队列。Metal GPU 执行错误由 completion 记录，在 `waitUntilIdle` 上抛出。

`CommandBuffer` 是 CPU 命令列表，记录后交给 `SubmissionPlanner`。规划器跟踪访问、状态转换及跨 queue 依赖；后端执行生成的 `SubmitPlan`。调用方只使用 capability 声明的队列；多个 API queue class 不代表多个独立硬件队列。命令记录器本身不支持并发写入。

`ComputePassEncoder.dispatch(groupsX:groupsY:groupsZ:)` 的单位为 **workgroup 数量**。每组的线程数由 shader module 的 `threadgroupSize` 决定，不能默认为一个线程。例如 local size 为 `(8,1,1)`，`dispatch(groupsX: 2)` 执行 16 个线程。`drawMeshTasks(x:y:z:)` 同样使用组数量。

## Shader 工具链边界

RHI 不依赖 Slang runtime 或 Slang reflection 类型。它接收 `ShaderModuleDescriptor`，也可以从离线 `ShaderArtifact` 构造该描述符。产物包含：

- shader stage、目标格式和 entry point；
- 二进制/源码 `Data`（JSON 中为 Base64）；
- `ShaderInterface`：local workgroup size 和目标资源绑定；
- 编译器标识，便于重现。

Metal 接收 MSL source / metallib，Vulkan shader 原型接收 SPIR-V，DX12 接口预留 DXIL。产物是目标专用的，需要为不同后端分别编译。反射不是跨后端统一 register ABI；工具链必须明确降低绑定。当前工具拒绝目标资源槽冲突和不支持的复合绑定，避免猜测映射。

`scripts/compile-rhi-shader.py` 固定 Slang **2026.19**，显式接收 `--slangc` 或 `SLANGC`，编译阶段不下载工具。原始 JSON reflection 与产物一起保存，便于检查。编译失败、版本不符或反射不合法时，不覆盖已有产物。

这一版本 Slang 的 compute JSON reflection 提供 local size，但 mesh / task JSON reflection 缺少该字段。因此 mesh / task 编译必须显式传 `--threadgroup-size X Y Z`，与 shader 的 `numthreads` 保持一致；能获得反射时，会检查显式值是否冲突。这里仍需要调用方保证 mesh 的声明一致。

本阶段验证了 Slang → MSL compute、mesh、fragment，以及 Slang → SPIR-V 编译。Metal 光追测试使用原生 MSL intersector；不把 Slang Metal RT 或 Metal Shader Converter 当作已完成的依赖。DXIL 还需要下游 DXC/dxcompiler，本机未安装，未验证该目标。

### 安装与验证

首次在 macOS arm64 上准备依赖：

```sh
python3 scripts/bootstrap-rhi-vulkan.py
python3 scripts/bootstrap-rhi-slang.py
export SLANGC="$PWD/Engine/vendor/slang/bin/slangc"
# 如果 ICD 不在系统搜索路径中，显式指定其 manifest；下面是 Homebrew 的例子。
export VK_DRIVER_FILES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json
```

Vulkan bootstrap 从校验过 SHA-256 的 Vulkan-Headers / Vulkan-Loader **1.4.328** 源码构建 macOS 13 deployment target 的 XCFramework，需要 Xcode command line tools 和 CMake。它只安装 loader；Vulkan GPU 测试仍需要单独安装 ICD（例如 MoltenVK）。已有 loader 会保留，可用 `--destination` 另建。Slang installer 同样校验固定发行包。所有编译器和 loader 二进制位于忽略的 `Engine/vendor`，不提交 Git。

```sh
python3 scripts/compile-rhi-shader.py \
  Engine/Tests/NativeRHITests/Fixtures/compute.slang \
  --entry computeMain --stage compute --target metal \
  --output /tmp/guava-compute.json

python3 scripts/compile-rhi-shader.py \
  Engine/Tests/NativeRHITests/Fixtures/mesh.slang \
  --entry meshMain --stage mesh --target metal \
  --threadgroup-size 3 1 1 --output /tmp/guava-mesh.json

SLANGC="$PWD/Engine/vendor/slang/bin/slangc" \
  swift test --package-path Engine --filter 'NativeRHITests\.' --jobs 4
python3 scripts/test-rhi-shader-toolchain.py
python3 scripts/check-swift-maintainability.py
```

没有 `SLANGC` 时，Swift shader 编译集成测试会明确 skip。没有对应 GPU / ICD 时，硬件测试会明确 skip；跳过不构成功能已验证的证据。

## Mesh 与光追最小接口

Mesh 使用独立 `MeshPipelineDescriptor`，不将 mesh 和传统 vertex pipeline 塞进同一组可空字段。当前支持无 task 的 mesh + 可选 fragment；local size 与原生 pipeline 限制会检查。depth/stencil mesh state 暂不支持，会明确报错。

AS 输入分为 `.bottomLevel([TriangleGeometry])` 和 `.topLevel([AccelerationInstance])`：

- BLAS 当前只支持不透明、非索引、float32 xyz 三角形；vertex offset / stride 按 4 字节对齐，输入范围会校验。
- TLAS 引用已经创建的 BLAS，instance transform 为三个 `SIMD4<Float>` 行组成的 3×4 仿射矩阵。矩阵必须有限，默认单位变换，mask 默认 `0xff`。
- 创建只分配对象；`device.recordBuild(structure, into: commands)` 才记录 GPU 构建。先构建 BLAS，再构建引用它的 TLAS，再提交查询。
- 规划器把输入标记为读取，把输出标记为 AS 写入；后端保留构建和间接访问所需的原生资源，并声明 TLAS 的 BLAS 依赖。
- 当前只有 compute 中的 closest-hit opaque triangle 查询；没有 alpha-test、procedural geometry、intersection enumeration 或 RT pipeline。

## 后续实现顺序

1. 用一个独立 renderer pass 接入 `NativeRHI`，补齐实际资源布局、渲染目标和 GPU 性能验证，再迁移现有 `RenderBackend`。
2. 完成 Vulkan descriptor / pipeline layout、render-pass 生命周期、texture barrier 与 copy，验证 raster / compute 后再打开 capability。
3. 在原生 Vulkan 设备验证 BLAS / TLAS / ray query 与 mesh；随后再扩展 RT pipeline / SBT、AS update / compaction。
4. 在 Windows 建立 DX12 编译与 GPU 测试；工具链可增加 DXC 等产物生成器，复用 `ShaderArtifact` 契约。
5. 根据 renderer 需求扩展 argument buffer / bindless、多 set、task、间接 mesh 与跨后端 shader ABI；每次只打开完成并验证的能力。
