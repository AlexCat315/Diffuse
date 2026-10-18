# Accessibility

语义树由组件的 `Node.accessibility` 与 `Node.accessibilityActions` 组成。`AccessibilityTree.snapshot` 负责可见性过滤、组合文本、值解析与 `describedBy` 关系解析；原生 macOS 桥和 DevTools 查询都消费同一套语义。

## 语义字段

| 字段 | 说明 |
| --- | --- |
| `role` | 标准角色；新增 `scrollArea` / `comboBox` |
| `label` / `value` / `help` | 名称、值、hint；help 同时用于 tooltip 描述 |
| `identifier` | 供 `describedBy` 引用的稳定标识 |
| `describedBy` | 另一个元素的 identifier；其 label（空时用 value）追加到当前 help |
| `state` | selected/expanded/disabled/required/invalid/readOnly/secure |
| `combinesChildren` | 组合装饰文本，但保留嵌套可操作控件 |

```swift
Text("Applies to the current workspace.")
    .accessibilityIdentifier("workspace-hint")

Button("Apply to workspace") { apply() }
    .accessibilityDescribedBy("workspace-hint")
```

`describedBy` 在 `AccessibilityTree.snapshot` 与 DevTools 的节点查询中都会解析；目标缺失或隐藏时保持原 help 不变，不产生空描述。引用目标不会成为额外 Tab 停靠点。

## 容器与单控件修饰

纯名称/描述修饰可穿透包裹单个语义控件的布局层；显式设置 `group`、dialog、table、tree、list、row、cell 或 status 时则作用于容器自身，保留内部动作角色。不能因只剩一个按钮就把按钮变成 group。`AgentControlDiscoveryTests.groupRoles` 覆盖 0/1/2 个按钮及真实 AI 工具查询。

## 滚动与选择

- `ScrollView`：`.scrollArea` 角色、可命名 `accessibilityLabel`、百分比 value、键盘滚动 help、按页 increment/decrement。滚动条 thumb 仍不是独立可聚焦节点。
- `Select` / `Combobox`：触发器为 `.comboBox`，label/value 为当前选项，`isExpanded` 反映弹层。
- macOS 原生桥映射 `scrollArea` 与 `comboBox`；Android 桥暂无对应映射。

## 边界

- `describedBy` 是单跳引用；不递归展开目标的描述，也不检测循环引用。
- 语义快照按可见裁剪与交互可用性过滤；隐藏目标不参与解析。
- 独立 `Scrollbar` companion 提供可聚焦 thumb；`ScrollView` 不会自动叠加它。平台专用 live region 仍未实现。
- 读屏实际播报依赖宿主原生桥；单元测试与 DevTools 查询验证语义树内容，不替代真机读屏取样。

## 验证

- `AccessibilitySemanticsTests.describedBy`：引用目标的标签追加到 help，缺失引用不改写 help。
- `AccessibilitySemanticsTests.scrollArea`：scrollArea 的 label/value/help 与 increment 后位置变化。
- `AccessibilitySemanticsTests.comboBoxes`：两个选择控件的 comboBox 角色、当前值、展开态与 activate。
- DevTools `button` 页查询 `Apply to workspace` 得到 `Apply to workspace. Applies to the current workspace.`；`scrollView`/`select` 页分别验证 scrollArea 与 comboBox。

## File map

- 语义树：[Accessibility.swift](../../GuavaUI/Portable/Sources/GuavaUIScene/Accessibility.swift)
- DevTools 查询：[Queries.swift](../../GuavaUI/Portable/Sources/GuavaUIDevToolsScene/Diagnostics/Queries.swift)
- 测试：[AccessibilitySemanticsTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/AccessibilitySemanticsTests.swift)
