# 几何创作基础

`AssetPipeline` 现在同时支持导入网格和保留建模过程的原生 `.dmesh` 资产。控制网格保存共享顶点、多边形、逐角 UV 与材质槽；只有求值结果转换成现有的 24-float GPU 顶点格式。改变修改器参数不覆盖控制网格。

## 本轮可用能力

| 路径 | 实现 |
| --- | --- |
| 多边形 | `PolygonMesh`、顶点集合平移、单面挤出、凹多边形三角化 |
| 参数化源 | 立方体、XZ 网格，可配置尺寸与网格分段 |
| 曲线 | 三次贝塞尔样条、绝对坐标手柄、开闭曲线、管状扫掠与端盖 |
| 修改器 | 镜像、阵列、Catmull–Clark 细分、实体化；可排序、启停和序列化 |
| 表面数据 | 平面/平滑法线、UV 插值与接缝、切线及 handedness、PBR 材质槽 |
| 资产流程 | JSON 原生文件、原子保存、项目扫描、资源导入、重载、GPU 目录更新 |

曲线使用平行移动标架，闭合曲线会分摊标架闭环误差；沿世界竖直方向扫掠也有稳定标架。曲线 UV 在圆周接缝处按角分离，控制网格保持连接。

## Swift API

```swift
import AssetPipeline

var control = try GeometryPrimitives.box(size: SIMD3(1, 1, 1))
try control.extrude(face: 3, by: SIMD3(0, 0.5, 0))

let document = GeometryDocument(
    name: "Rounded column",
    source: .polygon(mesh: control),
    modifiers: [
        .init(.subdivision(levels: 2)),
        .init(.array(count: 4, offset: SIMD3(2, 0, 0)))
    ],
    shading: .smooth
)
try document.save(to: projectURL.appendingPathComponent("Assets/Column.dmesh"))
let result = try document.evaluate()
// result.controlMesh: 最终控制拓扑
// result.mesh: 现有渲染器可消费的 MeshAsset
// result.topologySlice: 线框索引到共享位置池的映射
```

`.source` 是原始控制数据；`result.controlMesh` 是按顺序应用所有启用修改器后的结果。编辑方法仅在选择、索引和预算有效时提交；烘焙会进一步拒绝退化或自交多边形。网格槽位和 GPU 资源由原有 `AssetRegistry` / `NativeMeshStore` 管理。

## 原生格式

最小文件：

```json
{
  "version": 1,
  "name": "Cube",
  "source": { "box": { "size": [2, 2, 2] } }
}
```

默认使用平面法线、一个不透明非金属材质、空修改器栈。完整格式使用 Swift Codable 的带标签枚举；向量编码为数组。`source` 支持 `polygon`、`box`、`grid`、`tube`；修改器项包含 `enabled` 与 `operation`。完整可导入示例位于 [examples/GeometryAuthoring](../../examples/GeometryAuthoring/README.md)。

网格多边形包含 `vertices`、`materialIndex` 和可选 `uvs`；`vertices` 指向 `positions` 共享位置池，`uvs` 的长度必须等于多边形角数。文件没有外部依赖，复制和游戏资源打包沿用现有的模型资产流程。重载 `.dmesh` 会重新求值并保留路径对应的 meshIndex。原生几何保留场景尺寸与偏移。

## 当前边界

- 这是引擎 API 和资产链路；尚未加入视口顶点/边/面选择工具、修改器面板或节点图编辑器。
- 细分和实体化要求一致绕序的流形曲面，可有边界；不支持非流形边或顶点。细分支持 0–6 级，尚无边折痕权重。
- 镜像只焊接反射平面上的顶点，不裁切跨平面的面，也不移除已有的内部封口。阵列生成实际几何，不是渲染实例。
- 实体化按顶点法线对称偏移并封闭边界，不计算尖角的等距交线，也不消除厚壳自交。正厚度是必需的。
- 多边形最多 256 个角，三角化在主轴投影中进行，适合简单多边形；强烈扭曲的面应先拆分。单面挤出不支持面集合的区域挤出。
- 管道使用固定分段采样，不是自适应弧长采样；不消除管道自交，重合采样或尖点会报错。端盖使用同一平滑模式。
- 默认限制为 25 万控制/渲染顶点、100 万多边形角，最多 256 个修改器与材质槽；文件上限 32 MiB。增长检查在分配结果前执行。
- 原生材质当前保存颜色、金属度与粗糙度；纹理节点、纹理绘制、雕刻、元球和几何节点图尚未实现。

## 其余创作能力的推进顺序

现有模块已经提供物理、动画播放、实时渲染、路径追踪、序列与媒体编辑的基础；这不代表与完整 DCC 工作流等价。后续以可操作的端到端能力推进：

| 阶段 | 能力 | 接入点与验收 |
| --- | --- | --- |
| 建模交互 | 顶点/边/面选择、区域挤出、倒角、修改器面板 | 控制网格编辑、撤销事务、选择拾取；保存重开结果一致 |
| 程序化几何 | 带类型端口的 DAG、参数输入、实例化与缓存 | 复用几何源/修改器；检测循环、预算传播与依赖失效 |
| 表面创作 | UV 展开、绘制层、材质节点编译 | 材质槽及切线流；实时与最终渲染使用同一材质定义 |
| 动画创作 | 时间轴关键帧、曲线插值、形态键、IK 与动作混合编辑 | SceneRuntime / ScriptRuntime / SequenceRuntime；时间采样与保存回放一致 |
| 模拟扩展 | 风场与缓存编排、烟火/液体求解器、发丝系统 | 现有物理后端与渲染提取；确定性回放、缓存版本及组合模拟 |
| 后期整合 | 合成图、序列片段效果、追踪与遮罩 | SequenceRuntime / Media / RenderBackend；预览与导出一致 |

这些属于后续实施范围，本轮不以占位接口宣称已经具备。
