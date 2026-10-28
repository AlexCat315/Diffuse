# 几何建模示例

在 Diffuse 资源浏览器中导入 `Assets/` 下的三个 `.dmesh`，然后拖入场景：

- `RoundedArray.dmesh`：立方体 → Catmull–Clark 细分 → 阵列。
- `Shell.dmesh`：参数化网格 → 细分 → 带边界封口的实体化。
- `BezierPipe.dmesh`：三点贝塞尔曲线 → 带端盖的管道。

这些文件是 JSON，可通过项目文件编辑器或 Agent 修改。更改尺寸、曲线手柄、修改器参数、顺序或 `enabled` 后重新加载资源，现有实体继续使用同一网格槽位。`.dmesh` 使用场景单位，不会自动缩放到单位包围盒。

API、格式与当前限制见 [GeometryAuthoring](../../Engine/Documentation/GeometryAuthoring.md)。
