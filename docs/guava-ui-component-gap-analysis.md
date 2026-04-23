# GuavaUI 组件缺口清单（Inspector / Editor 工作流）

范围只看当前 Swift Editor 和 `legacy/react-editor` 里已经被证明需要的编辑器工作流组件，不讨论通用 UI 套件的长尾控件。

## 本轮已补齐

- `Toggle` 已有键盘 `Space` / `Enter` 激活
- 新增 `Checkbox`，与 `Toggle` 共享同一套 bool 输入语义
- 新增 `NumberField`，Inspector 的 Transform 已从字符串 `"x, y, z"` 改为真实数值编辑

## 仍然缺少或不完整的项

| 能力 | 当前状态 | 旧 Editor 对标 | 优先级 | 说明 |
| ---- | ---- | ---- | ---- | ---- |
| `Select` / `EnumField` | 缺失 | `EnumField` | 高 | 旧 Inspector 已用下拉编辑枚举；Swift 侧还没有统一的 menu / select 原语 |
| `AssetRefField` / 资源选择器 | 缺失 | `AssetRefField`, `SkyEnvironmentField` | 高 | 旧 Inspector 已支持 asset 下拉、拖放脚本 / HDR；Swift 侧还没有资源引用输入 |
| `ColorField` | 缺失 | `ColorField` | 高 | 旧 Inspector 已有 vec4 -> color picker 路径；Swift 侧仍只能读文本 |
| `Menu` / `Popover` | 缺失 | Add Component dropdown, tab context menu | 高 | 影响 Add Component、枚举输入、Dock 右键菜单等多个工作流 |
| `InspectorSection` 折叠头 | 不完整 | `CollapsibleSection` | 中 | Swift Inspector 目前是静态 `PropertyGridSection`，没有折叠 / 移除 / hover affordance |
| `AssetDropTarget` | 缺失 | Inspector script/HDR drop zone | 中 | 旧 Inspector 支持脚本拖放、HDR 拖放；Swift 侧还没有复用级 drop target primitive |
| `Vec3Field` 专用原语 | 半完成 | `Vec3Input` | 中 | 现在是三联 `NumberField` 组合，已可用，但还没有 per-axis 颜色、统一 step、拖拽 scrub |
| `JsonField` / 代码型多行编辑 | 缺失 | Script parameters editor | 中 | 旧 Inspector 已有脚本参数 JSON 编辑；Swift 侧只有通用 `TextField(axis: .vertical)` |
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

1. `Menu` / `Popover` + `Select`
2. `AssetRefField` + `AssetDropTarget`
3. `ColorField`
4. `InspectorSection` 折叠头
5. `Vec3Field` 专用交互增强
6. `JsonField` 或轻量代码编辑器
