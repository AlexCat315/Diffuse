# GuavaUI Phase 7.5 — 收尾总结

> 配套 `guava-ui-phase7.5-design.md`，记录 11 步实施完成后的验收结果、API 终态、已知坑、与 Phase 8 的接口面。

---

## 1. 完成度对照

| 步骤 | 设计文档对应 §| 落地状态 | 关键产出 |
|------|--------------|---------|----------|
| 1 | §3 / CompositionLocal 栈 | ✅ | `CompositionLocal<T>` + `Node.compositionValue(of:)` 走父链查找 |
| 2 | §3 Token 体系 | ✅ | `Theme` / `ColorScheme` / `Typography` / `SpacingScale` / `RadiusScale` / `ElevationScale` / `MotionScale` |
| 3 | §4 `DefaultDarkTheme` | ✅ | `Theme.defaultDark` 静态 |
| 4 | §5 主题分发 | ✅ | `ThemeEnvironment.key` + `.theme(_:)` + `Node.theme` 便捷读取 |
| 5 | §6 语义入口 | ✅ | `SemanticColorRef` / `SemanticFontRef` + `.foregroundColor(_:)` / `.background(_:)` / `.font(_:)` 重载 |
| 6 | §7 ButtonStyle | ✅ | `ButtonStyle` 协议 + `PrimaryButtonStyle` / `SecondaryButtonStyle` / `GhostButtonStyle` / `DestructiveButtonStyle` / `PlainButtonStyle` |
| 7 | §7 其余 Style | ✅ | `TextFieldStyle` / `PanelStyle` / `ListRowStyle` / `TreeRowStyle` / `DividerStyle` 协议骨架 + 默认实现 |
| 8 | §9 组件改造 | ✅ | `Panel` / `List` / `Tree` 改为 composite-with-host；`TextField` / `Divider` 主题感知 |
| 9 | `DefaultLightTheme` + Appearance | ✅ | `Theme.defaultLight` + `Appearance` 枚举 + `.appearance(_:)` modifier |
| 10 | §10 Demo 改造 | ✅ | `GuavaUIDemo/main.swift` 全语义化，含 light/dark 实时切换按钮 |
| 11 | §12 测试 | ✅ | 9 个集成测试 + 各 Style 单测；179/179 通过 |

---

## 2. 测试统计

- 总数：**179 / 179** 通过
- Phase 7.5 新增：约 37 个
  - `CompositionLocalTests` — 7
  - `ThemeTests` — 6
  - `ThemeEnvironmentTests` — 6
  - `ButtonStyleTests` — 6
  - `StyleSkeletonTests` — 7
  - `AppearanceTests` — 5
  - `StyleIntegrationTests` — 9（端到端）

---

## 3. 终态 API 速查

### 主题切换
```swift
RootView()
    .appearance(.dark)         // 或 .light
// 等价于：
RootView()
    .theme(Theme.defaultDark)  // 直接传值
```

### 语义颜色 / 字体
```swift
Text("hello")
    .font(.body)                       // SemanticFontRef.body
    .foregroundColor(.onSurface)       // SemanticColorRef.onSurface

Box { … }
    .background(.surfaceVariant)
```

### Button styles
```swift
Button("OK") { … }                     // 默认 = .primary
Button("Cancel") { … }.buttonStyle(.secondary)
Button("Skip") { … }.buttonStyle(.ghost)
Button("Delete", role: .destructive) { … }.buttonStyle(.destructive)
Button("ChevronOnly") { … }.buttonStyle(.plain)   // 无 chrome
```

### 自定义 Style
```swift
struct PillButtonStyle: ButtonStyle {
    func makeBody(_ c: ButtonStyleConfiguration) -> AnyView { … }
}
RootView().buttonStyle(PillButtonStyle())          // 子树批量替换
```

---

## 4. 关键设计决策（落地记录）

### 4.1 `Appearance` 而非 `ColorScheme`
SwiftUI 用 `ColorScheme`，但 GuavaUI 已有 `ColorScheme` 作为 token 槽位结构体。冲突无法回避，因此外观枚举取名 `Appearance`，与 SwiftUI 命名分歧但语义清晰。

### 4.2 Composite-with-host 模式
`Panel` / `List` / `Tree` 都拆为 **公开 composite View** + **内部 `XxxHost: _PrimitiveView`**。Host 的 `_children(for: Node)` 在父链已建立后读取 `node.compositionValue(of: XxxStyleEnvironment.key)`，把 style.makeBody(config) 的结果作为子 View 返回。这样 Style 可被 `.xxxStyle(_:)` 在子树批量替换。

### 4.3 `DefaultListRowStyle` 三分支返回
原始实现给所有行（包括 idle 状态）套了 `.background(.clear)`。这导致测试通过 backgroundColor 判定选中行时数量错乱。最终改为 selected / hovered / idle 三分支，idle 不套 `.background`。

### 4.4 主题感知原语 vs Composite-with-host
`Divider` / `TextField` 没有显式 Style 协议接入（仅有 Style skeleton 定义），主题感知通过在 `_updateNode` 里读 `node.theme` 然后写 `backgroundColor` / `cornerRadius`。**已知限制见下节**。

### 4.5 `PlainButtonStyle`
Tree 的 disclosure 三角必须可点击但不能带 Button chrome，否则会污染行布局。新增 `.buttonStyle(.plain)`，`makeBody` 直接 `AnyView(configuration.label)`。

---

## 5. 已知坑 / 后续改进

### 5.1 `_updateNode` 读 `node.theme` 时机
`Divider().appearance(.light)` 这种把 `.appearance` 直接挂在原语上的写法，原语在 `_updateNode` 阶段拿到的还是 `Theme.defaultDark`（fallback）。原因：`compositionLocal` modifier 创建的合成 anchor 还没成为该原语节点的父节点。

**当前规避**：
- 包一层 composite View（`Panel { Divider() }.appearance(.light)`）— 子节点在 anchor 之下
- 或改用 `SemanticBackgroundModifier` 路径（`.background(.divider)`），它在 apply 阶段解析

**修复方向**（Phase 8 候选）：把主题感知原语挂的属性改为 modifier-style 延迟应用，或在 `ViewGraph` 把 anchor 链建立提前到 `_updateNode` 之前。

### 5.2 `MotionScale` 仅生产，不消费
按设计文档原计划，动画系统在 Phase 8 落地。

### 5.3 Hover 状态未联通
`ButtonStyleConfiguration.isHovered` 字段已留位，但 PlatformShell 还没把 hover 事件喂进 Recomposer。

### 5.4 主题热重载
当前切换主题会重建整棵子树。未来可在 `ThemeEnvironment` 上挂 `@State` + diffing 优化，但首版不做。

---

## 6. 与 Phase 8 的接口面

Phase 8 计划接入动画系统（`MotionScale` 消费方），需要的入口已在 Phase 7.5 备好：

- `Theme.motion`：包含 `MotionToken` 三档（`fast` / `medium` / `slow`），可直接被未来的 `withAnimation(.semantic(.fast)) { … }` 使用
- `Style` 协议返回 `AnyView`，未来可在 makeBody 里包动画 modifier 而不破坏 API
- `Appearance` 切换路径（重新下发 Theme）天然适合做 cross-fade 动画

---

## 7. 文件 / 测试索引

实现：`GuavaUI/Sources/GuavaUICompose/Theme/` + `GuavaUI/Sources/GuavaUICompose/Primitives/`
测试：`GuavaUI/Tests/GuavaUIComposeTests/{CompositionLocalTests,ThemeTests,ThemeEnvironmentTests,ButtonStyleTests,StyleSkeletonTests,AppearanceTests,StyleIntegrationTests}.swift`
Demo：`GuavaUI/Sources/GuavaUIDemo/main.swift`

构建命令：
```bash
cd GuavaUI && swift build --product GuavaUIDemo
cd GuavaUI && swift test
```
