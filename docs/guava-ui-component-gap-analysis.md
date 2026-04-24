# GuavaUI 组件缺口清单（Inspector / Editor 工作流）

范围只看当前 Swift Editor 和 `legacy/react-editor` 里已经被证明需要的编辑器工作流组件，不讨论通用 UI 套件的长尾控件。

## 本轮已补齐

- `Toggle` 已有键盘 `Space` / `Enter` 激活
- 新增 `Checkbox`，与 `Toggle` 共享同一套 bool 输入语义
- 新增 `NumberField`，Inspector 的 Transform 已从字符串 `"x, y, z"` 改为真实数值编辑
- 新增 `Vec3Field`，Inspector 的三轴 Transform 改为紧凑、可收缩、带 X/Y/Z 轴标识的正式组件
- `PropertyGrid` 行布局改成更紧凑的可裁剪模式，避免窄 Inspector 中字段溢出
- 新增 `AssetDropTarget` / `AssetRefField` 基础版，补上资源引用行、清空、按类型接收 drop 的 GuavaUI primitive
- 新增 `JsonField` 基础版，覆盖脚本参数类 JSON 编辑、校验、格式化和有效提交语义

## 仍然缺少或不完整的项

| 能力 | 当前状态 | 旧 Editor 对标 | 优先级 | 说明 |
| ---- | ---- | ---- | ---- | ---- |
| `Menu` / `Popover` | 已有基础版，不完整 | Add Component dropdown, tab context menu | 高 | 当前实现仍是布局内展开，不是真正 overlay；会挤压 Inspector/Toolbar 布局 |
| `Select` / `EnumField` | 已有基础版，不完整 | `EnumField` | 高 | 已能承载 light type 等枚举，但依赖当前 `Popover`，需要 overlay、键盘导航和焦点关闭语义 |
| `AssetRefField` / 资源选择器 | 基础版已接入组件层 | `AssetRefField`, `SkyEnvironmentField` | 高 | 已有资源引用行、清空、按类型 drop；仍缺少浏览/选择器、预览缩略图、具体 Inspector 字段绑定 |
| `ColorField` | 已有基础版，不完整 | `ColorField` | 高 | 已有 swatch + RGBA/HEX panel，但仍依赖布局内 popover，缺少 eyedropper / preset / overlay 行为 |
| `InspectorSection` 折叠头 | 不完整 | `CollapsibleSection` | 中 | Swift Inspector 目前是静态 `PropertyGridSection`，没有折叠 / 移除 / hover affordance |
| `AssetDropTarget` | 基础版已接入组件层 | Inspector script/HDR drop zone | 中 | 已有 registry + hit-test + typed payload；仍需要文件级拖入、hover 精确状态和 Editor 字段落地 |
| `Vec3Field` 专用交互增强 | 基础版已接入 | `Vec3Input` | 中 | 已有 per-axis 颜色和统一 step/min/max；仍缺少拖拽 scrub、重置轴值、复制/粘贴 vector |
| `JsonField` / 代码型多行编辑 | 基础版已接入组件层 | Script parameters editor | 中 | 已有 JSON 校验、格式化、有效提交；仍缺少 schema-aware 提示、错误定位和具体 Script Inspector 字段绑定 |
| `Stepper` / drag scrub | 缺失 | FloatField + number UX | 低 | 不是闭环阻塞项，但会直接影响数值编辑效率 |

## 排序依据

- 高：直接阻塞旧 Inspector 已有的组件编辑能力迁移
- 中：已有替代方案，但缺少编辑器级交互质量
- 低：已有可用路径，只是效率或精细度不够

## 参考文件

- Swift Inspector: `Editor/Sources/EditorApp/Panels/InspectorPanel.swift`
- Swift 场景适配层: `Editor/Sources/EditorCore/Scene/EditorSceneAdapter.swift`
- 旧 Inspector: `legacy/react-editor/src/renderer/panels/Inspector.tsx`
- 当前组件索引: `docs/components/README.md`

## 建议顺序

1. `Menu` / `Popover` overlay 化 + `Select` 键盘/焦点语义
2. `AssetRefField` + `AssetDropTarget` 接到 Mesh/Sky/Script 等实际 Inspector schema
3. `ColorField` overlay 化和 Inspector 行内适配
4. `InspectorSection` 折叠头
5. `Vec3Field` 专用交互增强
6. `JsonField` 接到 Script parameters schema，并补 schema-aware 提示
