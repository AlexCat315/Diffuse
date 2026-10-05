# 网格拾取、材质与大场景渲染

点击选中使用真实三角形表面和缓存 BVH；射线转换到模型空间后保留世界距离，支持旋转、非均匀缩放、负缩放以及当前骨骼姿势。软体使用当前模拟顶点。渲染模型未命中时，其碰撞体不会再次把空白区域选中；没有渲染网格的碰撞体仍可选中。框选继续使用屏幕包围区域。

glTF 导入遵循 `alphaMode`、`alphaCutoff` 和 `doubleSided`：默认 OPAQUE 忽略 alpha，MASK 默认阈值 0.5，BLEND 按视轴深度从远到近混合且不写深度。MASK 的纹理孔洞同时用于颜色、深度、描边和阴影；双面背面法线翻转。BLEND 不投射实心阴影。它提供透明度混合，玻璃折射、物理透射与相交透明面的逐像素排序尚未实现。[glTF 2.0 规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)

`RenderMaterial` 和 `RenderMaterialComponent` 的 `alphaMode`、`alphaCutoff`、`doubleSided` 为可选覆盖值；nil 保留导入材质设置。这些值在编辑器场景保存与加载时保留。普通材质参数编辑也会保留这些覆盖值。

## 大场景设置

`RenderSettings.enableFrustumCulling`、`enableMeshInstancing`、`enableDistanceLOD` 默认开启。视锥剔除适用于透视与正交相机，保守保留未知包围盒或骨骼模型。阴影独立绘制全部可投影物体，防止视口外物体的阴影消失。同一网格、子网格和材质的静态实例合并绘制，颜色可逐实例变化；透明、骨骼与软体实例独立绘制。渲染 bundle 使用同一批次，因此保留材质与实例化行为。

LOD 需要提供作者制作的简化网格，避免自动减面破坏 UV、材质边界或模型轮廓。将这些网格注册到同一网格表，在运行时或场景文件配置距离：

```swift
let mesh = RenderMeshHandle(meshIndex: 2, levelsOfDetail: [
    RenderMeshLOD(meshIndex: 3, minimumDistance: 20),
    RenderMeshLOD(meshIndex: 4, minimumDistance: 60)
])
```

ECS 使用 `RenderMeshComponent.levelsOfDetail`，编辑器场景 JSON 的 `renderMesh.levelsOfDetail` 保存 `meshIndex` 和 `minimumDistance`。距离使用世界单位；缺少指定网格时继续使用可用层级。骨骼与软体不切换静态 LOD，阴影使用原始网格。

`RenderFrameStats` 提供 `visibleMeshInstanceCount`、`culledMeshInstanceCount`、`lodMeshInstanceCount`、`meshBatchCount`、`instancedMeshBatchCount` 和 `submittedMeshTriangleCount`，可以核对优化是否生效。

## 自动真实 GPU 回归

新增 `.github/workflows/ci-gpu.yml`，覆盖透明混合、裁切深度与阴影、双面材质、实例化、LOD、阴影图集、骨骼、网格与正交视口，并上传像素 PPM、设备日志和 xUnit 报告。脚本检查 GPU 用例数量及跳过状态；无法获得显卡或编译管线会失败。

接入步骤：

1. 在 GitHub 仓库 **Settings → Actions → Runners** 查看是否已有 runner。没有时，点击 **New self-hosted runner**，选择 macOS ARM64，按页面命令在带 Metal GPU 的 Mac 上注册。可以使用专用 Mac mini。
2. 添加 `guava-gpu` 标签，安装 Swift 6.1 或更新版本、Xcode 命令行工具、CMake、Rust/Cargo、Python 3；确保 runner 账户可以使用 Metal。
3. 在 Actions 中手动运行 **GPU rendering regression**，确认测试及报告通过。
4. 在 **Settings → Secrets and variables → Actions → Variables** 添加 `GUAVA_GPU_CI_ENABLED=true`。随后 main 分支相关推送和每日定时任务自动运行。变量未设置时自动任务跳过，避免没有机器时长时间排队。

工作流使用 [GitHub 的 self-hosted runner 标签匹配](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)。它不由外部 PR 自动触发；普通跨平台 CI 保持运行无显卡测试。

本地执行：

```bash
bash scripts/test-gpu-regression.sh
```

可以设置 `GUAVA_SWIFT_EXECUTABLE` 指定 Swift 路径，或用 `GUAVA_GPU_TEST_OUTPUT_DIR` 指定报告目录。
