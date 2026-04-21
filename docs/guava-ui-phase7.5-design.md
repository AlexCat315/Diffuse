# GuavaUI Phase 7.5 — Theme & DefaultStyles 详细设计

> 本文档是 `guava-ui-blueprint.md §11 Phase 7.5` 的展开实现规约。
> 目标读者：实现者本人、未来的代码评审者。
> 不重复蓝图里已经定调的内容，只补充落地决策、文件清单、接口签名、验收标准。

---

## 0. 范围与目标

**纳入 Phase 7.5**：

1. Token 体系：`ColorScheme` / `Typography` / `SpacingScale` / `RadiusScale` / `ElevationScale` / `MotionScale`。
2. 默认主题：`DefaultDarkTheme` / `DefaultLightTheme`，二者结构一致，仅 token 取值不同。
3. 主题分发：`Theme` 通过 `CompositionLocal<Theme>` 下发；`.theme(_:)` modifier 在子树覆盖。
4. 语义入口：`SemanticColor` / `SemanticFont` 把 token 暴露成 `Color.surface`、`Font.body` 这种调用方式。
5. 默认样式：为 `Button` / `TextField` / `Panel` / `List row` / `Tree row` / `Divider` 增加 `Style` 协议与默认实现。
6. `style(_:)` modifier：与 SwiftUI 的 `.buttonStyle` 同形态，可在子树批量切换。
7. 调用点改造：`GuavaUIDemo/main.swift` 与现有组件 demo 替换为基于 token 的写法，验收对照。

**不纳入 Phase 7.5**（属于 Phase 8 或更后）：

- 完整动画系统（`MotionScale` 仅生产 token，不消费）。
- 无障碍（焦点环颜色由 token 提供，但不接 VoiceOver / 高对比度自动切换）。
- 主题热重载与磁盘配置（首版仅在启动时切换）。
- 用户自定义 token 编辑器面板（属于 Editor 业务）。

---

## 1. 设计原则

| 原则 | 含义 |
|------|------|
| 默认即可看 | 任何组件不传任何 style 都能渲染出符合 MD3 / macOS Sonoma 同档次的外观 |
| Runtime 零侵入 | 所有 token 与 style 落 Compose 层，`GuavaUIRuntime` 不增加任何符号 |
| Token 不直读 | 调用点只用 `Color.surface` / `Font.body`，不写浮点 RGB 与像素字号 |
| Style 可替换 | 每个被覆盖的组件提供 `Style` 协议；默认实现不暴露内部布局，只暴露状态 |
| 主题是值 | `Theme` 是 struct，不可变；切换主题 = 重新下发新值，不写回 |
| 无主题也能跑 | `CompositionLocal<Theme>` 默认值即 `.defaultDark`，没有 `.theme(_:)` 调用也不会崩 |

---

## 2. 文件清单

```
GuavaUI/Sources/GuavaUICompose/
├── Theme/
│   ├── Theme.swift                     // Theme 聚合类型
│   ├── ColorScheme.swift               // 语义色 token
│   ├── Typography.swift                // 字体 token
│   ├── SpacingScale.swift              // 间距 token
│   ├── RadiusScale.swift               // 圆角 token
│   ├── ElevationScale.swift            // 阴影 token
│   ├── MotionScale.swift               // 时长 / 缓动 token（仅生产）
│   ├── DefaultDarkTheme.swift          // Theme.defaultDark
│   ├── DefaultLightTheme.swift         // Theme.defaultLight
│   ├── ThemeEnvironment.swift          // CompositionLocal<Theme> + .theme modifier
│   └── ThemeReader.swift               // ThemeReader { theme in ... }
├── Style/
│   ├── ButtonStyle.swift               // protocol ButtonStyle + ButtonStyleConfiguration
│   ├── PrimaryButtonStyle.swift
│   ├── SecondaryButtonStyle.swift
│   ├── GhostButtonStyle.swift
│   ├── DestructiveButtonStyle.swift
│   ├── TextFieldStyle.swift
│   ├── DefaultTextFieldStyle.swift
│   ├── PanelStyle.swift
│   ├── DefaultPanelStyle.swift
│   ├── ListRowStyle.swift
│   ├── DefaultListRowStyle.swift
│   ├── TreeRowStyle.swift
│   ├── DefaultTreeRowStyle.swift
│   └── DividerStyle.swift
└── Foundation/
    ├── SemanticColor.swift             // extension Color: surface/onSurface/...
    └── SemanticFont.swift              // extension Font: title/body/caption/...
```

---

## 3. Token API

### 3.1 Theme 聚合

```swift
public struct Theme: Sendable {
    public var colors: ColorScheme
    public var typography: Typography
    public var spacing: SpacingScale
    public var radius: RadiusScale
    public var elevation: ElevationScale
    public var motion: MotionScale

    public init(colors: ColorScheme,
                typography: Typography,
                spacing: SpacingScale,
                radius: RadiusScale,
                elevation: ElevationScale,
                motion: MotionScale)

    public static let defaultDark: Theme   = DefaultDarkTheme.value
    public static let defaultLight: Theme  = DefaultLightTheme.value
}
```

`Theme` 是值类型；任何字段都可以通过 `var copy = Theme.defaultDark; copy.colors.accent = ...` 派生。

### 3.2 ColorScheme

只暴露语义槽位，不暴露具体色号。

```swift
public struct ColorScheme: Sendable {
    // 表面层级
    public var background: Color           // 窗口最底
    public var surface: Color              // 卡片 / 面板
    public var surfaceVariant: Color       // 二级面板 / hover 态
    public var surfaceSunken: Color        // 输入框 / 凹面

    // 内容
    public var onBackground: Color
    public var onSurface: Color
    public var onSurfaceVariant: Color     // 次级文字
    public var onSurfaceMuted: Color       // 三级文字 / placeholder

    // 强调
    public var accent: Color
    public var onAccent: Color
    public var accentMuted: Color          // 半透明强调（tint 背景）

    // 状态
    public var success: Color
    public var warning: Color
    public var error: Color
    public var info: Color

    // 结构
    public var border: Color
    public var borderStrong: Color
    public var divider: Color
    public var focusRing: Color
    public var selection: Color            // 行选中底色
    public var overlay: Color              // modal 遮罩
}
```

### 3.3 Typography

字体 token 只暴露语义档位，由组件按场景选择。

```swift
public struct Typography: Sendable {
    public var display:  TextStyleToken    // 大标题 32 / bold
    public var title:    TextStyleToken    // 24 / bold
    public var headline: TextStyleToken    // 18 / semibold
    public var body:     TextStyleToken    // 14 / regular
    public var bodyStrong: TextStyleToken  // 14 / semibold
    public var caption:  TextStyleToken    // 12 / regular
    public var label:    TextStyleToken    // 11 / medium，用于 List/Tree row
    public var mono:     TextStyleToken    // 等宽，控制台与代码
}

public struct TextStyleToken: Sendable {
    public var font: Font
    public var lineHeight: Float
    public var letterSpacing: Float        // 默认 0
}
```

### 3.4 SpacingScale / RadiusScale / ElevationScale / MotionScale

```swift
public struct SpacingScale: Sendable {
    public var xs: Float    // 4
    public var sm: Float    // 8
    public var md: Float    // 12
    public var lg: Float    // 16
    public var xl: Float    // 24
    public var xxl: Float   // 32
}

public struct RadiusScale: Sendable {
    public var none: Float   // 0
    public var sm: Float     // 4
    public var md: Float     // 8
    public var lg: Float     // 12
    public var xl: Float     // 16
    public var pill: Float   // 9999
}

public struct ElevationScale: Sendable {
    public var none: Shadow
    public var low: Shadow      // 面板边缘
    public var medium: Shadow   // 浮窗
    public var high: Shadow     // ContextMenu / DockTab drag
}

public struct Shadow: Sendable {
    public var color: Color
    public var offsetX: Float
    public var offsetY: Float
    public var blur: Float
    public static let none = Shadow(color: .clear, offsetX: 0, offsetY: 0, blur: 0)
}

public struct MotionScale: Sendable {
    public var fast: Duration       // 100ms
    public var standard: Duration   // 200ms
    public var slow: Duration       // 320ms
    public var emphasized: Easing
    public var standardEasing: Easing
}
```

`Shadow` / `Easing` / `Duration` 在 Phase 7.5 仅作为类型存在；`Shadow` 由 `DrawList` 暂时降级为可选边框（Phase 7 已支持），完整阴影管线推迟。`MotionScale` 留接口供 Phase 8 消费。

---

## 4. 默认主题取值（DefaultDarkTheme）

> 取值参考 macOS Sonoma 暗色 / VS Code Dark+ / MD3 dark surface。可在实现期微调，本节作为对齐基准。

```swift
enum DefaultDarkTheme {
    static let value: Theme = Theme(
        colors: ColorScheme(
            background:       Color(red: 0x14, green: 0x16, blue: 0x1B),
            surface:          Color(red: 0x1C, green: 0x1F, blue: 0x26),
            surfaceVariant:   Color(red: 0x24, green: 0x28, blue: 0x30),
            surfaceSunken:    Color(red: 0x10, green: 0x12, blue: 0x16),

            onBackground:     Color(red: 0xEC, green: 0xEE, blue: 0xF2),
            onSurface:        Color(red: 0xE6, green: 0xE9, blue: 0xEF),
            onSurfaceVariant: Color(red: 0xAE, green: 0xB4, blue: 0xC0),
            onSurfaceMuted:   Color(red: 0x6E, green: 0x76, blue: 0x84),

            accent:           Color(red: 0x4C, green: 0x8B, blue: 0xF5),
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x4C, green: 0x8B, blue: 0xF5, alpha: 0x33),

            success:          Color(red: 0x4A, green: 0xC2, blue: 0x6B),
            warning:          Color(red: 0xE5, green: 0xA5, blue: 0x3F),
            error:            Color(red: 0xE5, green: 0x55, blue: 0x4D),
            info:             Color(red: 0x5E, green: 0xA8, blue: 0xE6),

            border:           Color(red: 0x2E, green: 0x33, blue: 0x3D),
            borderStrong:     Color(red: 0x40, green: 0x46, blue: 0x52),
            divider:          Color(red: 0x24, green: 0x28, blue: 0x30),
            focusRing:        Color(red: 0x4C, green: 0x8B, blue: 0xF5, alpha: 0x99),
            selection:        Color(red: 0x2E, green: 0x4F, blue: 0x8A),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0x99)
        ),
        typography: Typography(
            display:    .init(font: .system(size: 32, weight: .bold),    lineHeight: 38),
            title:      .init(font: .system(size: 24, weight: .bold),    lineHeight: 30),
            headline:   .init(font: .system(size: 18, weight: .semibold),lineHeight: 24),
            body:       .init(font: .system(size: 14, weight: .regular), lineHeight: 20),
            bodyStrong: .init(font: .system(size: 14, weight: .semibold),lineHeight: 20),
            caption:    .init(font: .system(size: 12, weight: .regular), lineHeight: 16),
            label:      .init(font: .system(size: 11, weight: .medium),  lineHeight: 14),
            mono:       .init(font: .system(size: 13, weight: .regular), lineHeight: 18)
        ),
        spacing:   SpacingScale(xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32),
        radius:    RadiusScale(none: 0, sm: 4, md: 8, lg: 12, xl: 16, pill: 9999),
        elevation: ElevationScale(
            none:   .none,
            low:    Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x40), offsetX: 0, offsetY: 1, blur: 2),
            medium: Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x55), offsetX: 0, offsetY: 4, blur: 12),
            high:   Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x66), offsetX: 0, offsetY: 8, blur: 24)
        ),
        motion: MotionScale(
            fast: .milliseconds(100),
            standard: .milliseconds(200),
            slow: .milliseconds(320),
            emphasized: .cubicBezier(0.2, 0.0, 0.0, 1.0),
            standardEasing: .cubicBezier(0.4, 0.0, 0.2, 1.0)
        )
    )
}
```

`DefaultLightTheme` 沿用同一结构与 typography / spacing / radius / motion，仅 `colors` 替换为亮色取值。

---

## 5. Theme 分发

### 5.1 CompositionLocal

升级 `GuavaUIRuntime/CompositionLocal.swift` 的 stub 至少需要支持栈式作用域查找。Phase 7.5 是 `CompositionLocal` 的第一个真实使用方。

```swift
public final class CompositionContext {
    public func push<Value>(_ key: CompositionLocal<Value>, value: Value)
    public func pop<Value>(_ key: CompositionLocal<Value>)
    public func value<Value>(of key: CompositionLocal<Value>) -> Value
}
```

`CompositionContext` 由 `ViewGraph` 在重组下行时维护；具体接入点在 `ModifiedContent+Materialise`。

### 5.2 ThemeEnvironment

```swift
public enum ThemeEnvironment {
    public static let key = CompositionLocal<Theme>(defaultValue: .defaultDark)
}

public extension View {
    func theme(_ theme: Theme) -> some View {
        modifier(_ProvideCompositionLocal(key: ThemeEnvironment.key, value: theme))
    }
}
```

读取通过 `ThemeReader` 暴露：

```swift
public struct ThemeReader<Content: View>: View {
    private let content: (Theme) -> Content
    public init(@ViewBuilder _ content: @escaping (Theme) -> Content) {
        self.content = content
    }
    public var body: some View {
        // 内部从 CompositionContext 读取 ThemeEnvironment.key
    }
}
```

组件内部可以走快路径：在 `materialise` 阶段直接从 `CompositionContext` 拿到 `Theme`，无需包 `ThemeReader`。

---

## 6. 语义入口

### 6.1 SemanticColor

`Color` 本身仍然是 struct（值类型），不能携带主题。语义色通过命名空间提供，必须有 `Theme` 上下文才能解析；解析失败 fallback 到 `.defaultDark`。

```swift
public struct SemanticColorRef: Sendable {
    let resolve: @Sendable (Theme) -> Color
}

public extension SemanticColorRef {
    static let surface          = SemanticColorRef { $0.colors.surface }
    static let surfaceVariant   = SemanticColorRef { $0.colors.surfaceVariant }
    static let onSurface        = SemanticColorRef { $0.colors.onSurface }
    static let onSurfaceVariant = SemanticColorRef { $0.colors.onSurfaceVariant }
    static let accent           = SemanticColorRef { $0.colors.accent }
    static let border           = SemanticColorRef { $0.colors.border }
    static let success          = SemanticColorRef { $0.colors.success }
    static let warning          = SemanticColorRef { $0.colors.warning }
    static let error            = SemanticColorRef { $0.colors.error }
    // ...
}
```

调用形态：

```swift
Text("Hello")
    .foregroundColor(.semantic(.onSurface))     // 新接口
    .background(.semantic(.surface))
```

为不破坏现有 `.foregroundColor(Color)` 调用点，新增 `Color` 重载：

```swift
public extension View {
    func foregroundColor(_ ref: SemanticColorRef) -> some View
    func background(_ ref: SemanticColorRef) -> some View
}
```

并保留旧的 `Color` 版本。`Color` 静态属性 `Color.surface` 不引入——会强迫 `Color` 持有主题引用，破坏值语义。

### 6.2 SemanticFont

```swift
public struct SemanticFontRef: Sendable {
    let resolve: @Sendable (Theme) -> TextStyleToken
}

public extension SemanticFontRef {
    static let display    = SemanticFontRef { $0.typography.display }
    static let title      = SemanticFontRef { $0.typography.title }
    static let headline   = SemanticFontRef { $0.typography.headline }
    static let body       = SemanticFontRef { $0.typography.body }
    static let bodyStrong = SemanticFontRef { $0.typography.bodyStrong }
    static let caption    = SemanticFontRef { $0.typography.caption }
    static let label      = SemanticFontRef { $0.typography.label }
    static let mono       = SemanticFontRef { $0.typography.mono }
}

public extension Text {
    func font(_ ref: SemanticFontRef) -> Text   // 同时设置 font / lineHeight
}
```

---

## 7. Style 协议

### 7.1 ButtonStyle

参考 SwiftUI 的 `ButtonStyle` + `Configuration` 模型。

```swift
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: ButtonStyleConfiguration) -> Body
}

public struct ButtonStyleConfiguration {
    public let label: AnyView          // 调用点传入的 label 内容
    public let role: ButtonRole        // .normal / .destructive / .cancel
    public let isPressed: Bool
    public let isHovered: Bool
    public let isFocused: Bool
    public let isEnabled: Bool
    public let theme: Theme
}

public enum ButtonRole: Sendable { case normal, destructive, cancel }
```

`Button` 组件本身只产出 `ButtonStyleConfiguration` 与一块可点击区域，外观完全交给 style。

```swift
public struct Button<Label: View>: View {
    public init(role: ButtonRole = .normal,
                action: @escaping () -> Void,
                @ViewBuilder label: () -> Label)

    // 便利构造
    public init(_ title: String,
                role: ButtonRole = .normal,
                action: @escaping () -> Void)
}
```

`buttonStyle` 通过 `CompositionLocal<AnyButtonStyle>` 下发；嵌套覆盖：

```swift
public extension View {
    func buttonStyle<S: ButtonStyle>(_ style: S) -> some View
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
public extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
public extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}
```

### 7.2 PrimaryButtonStyle 默认实现

```swift
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return theme.colors.accent.darker(0.10) }
            if configuration.isHovered  { return theme.colors.accent.lighter(0.06) }
            return theme.colors.accent
        }()
        return configuration.label
            .font(.semantic(.bodyStrong))
            .foregroundColor(.semantic(.onAccent))
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm)
            .background(bg, cornerRadius: theme.radius.md)
            .focusRing(visible: configuration.isFocused, color: theme.colors.focusRing)
            .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
```

`SecondaryButtonStyle` 用 `surfaceVariant` 背景 + `border` 描边；`GhostButtonStyle` 无背景，仅 hover 态着色；`DestructiveButtonStyle` 把 accent 替换为 `error`。

### 7.3 其余 Style

每个组件都遵循同一模式：组件本体只产数据与状态，`Style` 决定如何画。

| 组件 | Style 协议 | 默认实现 | Configuration 字段 |
|------|-----------|---------|--------------------|
| `Button` | `ButtonStyle` | `PrimaryButtonStyle`（也作为 `.theme` 默认） | label, role, isPressed, isHovered, isFocused, isEnabled, theme |
| `TextField` | `TextFieldStyle` | `DefaultTextFieldStyle` | text binding, placeholder, isFocused, isEditing, isError, theme |
| `Panel` | `PanelStyle` | `DefaultPanelStyle` | title, content, isActive, theme |
| `List` 行 | `ListRowStyle` | `DefaultListRowStyle` | content, isSelected, isHovered, theme |
| `Tree` 行 | `TreeRowStyle` | `DefaultTreeRowStyle` | content, depth, isSelected, isExpanded, hasChildren, theme |
| `Divider` | `DividerStyle` | `DefaultDividerStyle` | orientation, theme |

`Panel` 默认实现伪代码：

```swift
public struct DefaultPanelStyle: PanelStyle {
    public func makeBody(configuration: PanelStyleConfiguration) -> some View {
        let t = configuration.theme
        Column(spacing: 0) {
            Row(alignment: .center, spacing: t.spacing.sm) {
                Text(configuration.title).font(.semantic(.label))
                    .foregroundColor(.semantic(.onSurfaceVariant))
                Spacer()
            }
            .padding(horizontal: t.spacing.md, vertical: t.spacing.xs)
            .background(.semantic(.surfaceVariant))

            Divider().dividerStyle(DefaultDividerStyle())

            configuration.content
                .padding(t.spacing.md)
                .background(.semantic(.surface))
                .flex()
        }
        .background(.semantic(.surface), cornerRadius: t.radius.md)
        .border(.semantic(.border), width: 1, cornerRadius: t.radius.md)
    }
}
```

---

## 8. 修饰符扩展

为支撑上述 style，需要少量补强 modifier：

```swift
public extension View {
    func padding(_ amount: Float) -> some View
    func padding(horizontal: Float = 0, vertical: Float = 0) -> some View
    func background(_ ref: SemanticColorRef, cornerRadius: Float = 0) -> some View
    func background(_ color: Color, cornerRadius: Float = 0) -> some View
    func border(_ ref: SemanticColorRef, width: Float, cornerRadius: Float = 0) -> some View
    func opacity(_ value: Float) -> some View
    func focusRing(visible: Bool, color: Color) -> some View
}
```

`Color.darker(_:)` / `Color.lighter(_:)` 作为 token 派生工具，落在 `SemanticColor.swift` 同文件：

```swift
public extension Color {
    func darker(_ amount: Float) -> Color
    func lighter(_ amount: Float) -> Color
    func mixed(with other: Color, amount: Float) -> Color
}
```

实现走 sRGB 线性插值；`amount` 范围 0…1。

---

## 9. 现有组件改造清单

| 文件 | 改造点 |
|------|--------|
| [GuavaUI/Sources/GuavaUICompose/Primitives/Button.swift](GuavaUI/Sources/GuavaUICompose/Primitives/Button.swift) | 拆出内部点击区域，外观全部下放给 `ButtonStyle`；保留旧 `Button(action:label:)` 签名 |
| [GuavaUI/Sources/GuavaUICompose/Primitives/TextField.swift](GuavaUI/Sources/GuavaUICompose/Primitives/TextField.swift) | 默认背景 / 边框 / 焦点环走 `DefaultTextFieldStyle`；不再要求调用点写 `.padding(8).background(Color(...))` |
| [GuavaUI/Sources/GuavaUICompose/Primitives/Panel.swift](GuavaUI/Sources/GuavaUICompose/Primitives/Panel.swift) | 移除 `titleColor` 默认 `Color.white`；改为读 `theme.colors.onSurfaceVariant`；保留旧参数作为覆盖 |
| [GuavaUI/Sources/GuavaUICompose/Primitives/List.swift](GuavaUI/Sources/GuavaUICompose/Primitives/List.swift) | 行容器走 `DefaultListRowStyle`；`isSelected` 不再要求调用点自配色 |
| [GuavaUI/Sources/GuavaUICompose/Primitives/Tree.swift](GuavaUI/Sources/GuavaUICompose/Primitives/Tree.swift) | 同上，行容器走 `DefaultTreeRowStyle`；缩进数值取自 `theme.spacing.md` |
| [GuavaUI/Sources/GuavaUICompose/Primitives/SplitView.swift](GuavaUI/Sources/GuavaUICompose/Primitives/SplitView.swift) | 分隔条颜色取 `theme.colors.divider`；hover 态高亮取 `borderStrong` |
| [GuavaUI/Sources/GuavaUICompose/Primitives/Image.swift](GuavaUI/Sources/GuavaUICompose/Primitives/Image.swift) | `tint` 默认从 `theme.colors.onSurface` 取；保留显式 `tint:` 重载 |

旧调用点不需要任何修改即可继续工作（行为兼容）。新调用点鼓励改用 token。

---

## 10. Demo 改造目标

[GuavaUI/Sources/GuavaUIDemo/main.swift](GuavaUI/Sources/GuavaUIDemo/main.swift) 是 Phase 7.5 的对照样本。改造后的 `RootView` 不出现任何 `Color(r:g:b:)` 与 `.system(size:)` 字面量。

```swift
struct RootView: View {
    @State var inputText: String = ""
    @State var clickCount: Int = 0
    @State var selectedSceneNodeID: String? = "camera"
    @State var selectedLogID: Int? = 2

    var body: some View {
        SplitView(.horizontal, fraction: 0.22) {
            Panel("Hierarchy") {
                Tree(demoSceneTree, children: \.children, selection: $selectedSceneNodeID) { node, _, _, _ in
                    Text(node.title)
                }
                .flex()

                Divider()

                Button("Refresh Snapshot \(clickCount)") { clickCount += 1 }
                    .buttonStyle(.primary)
            }
        } second: {
            SplitView(.horizontal, fraction: 0.74) {
                SplitView(.vertical, fraction: 0.68) {
                    Panel("Workspace") {
                        Column(alignment: .leading, spacing: 12) {
                            Text("GuavaUI — Phase 7.5").font(.semantic(.title))
                            Text("Theme + DefaultStyles 已接入").font(.semantic(.body))
                                .foregroundColor(.semantic(.onSurfaceVariant))

                            TextField("Type here…", text: $inputText)

                            Text("echo: \(inputText)").font(.semantic(.body))
                            Spacer()
                        }
                    }
                } second: {
                    Panel("Console") {
                        List(demoLogEntries, selection: $selectedLogID) { entry, _ in
                            Row(spacing: 10) {
                                Text(entry.level).font(.semantic(.label))
                                    .foregroundColor(demoLogColor(entry.level))
                                Text(entry.message).font(.semantic(.body))
                            }
                        }
                        .flex()
                    }
                }
            } second: {
                Panel("Inspector") {
                    Column(alignment: .leading, spacing: 6) {
                        Text("selected: \(demoSceneTitle(id: selectedSceneNodeID))")
                            .font(.semantic(.body))
                        Text("type: EntityNode").font(.semantic(.caption))
                            .foregroundColor(.semantic(.onSurfaceMuted))
                        Spacer()
                    }
                }
            }
        }
        .flex()
        .background(.semantic(.background))
    }
}

graph.install(root: RootView().theme(.defaultDark))
```

`demoLogColor` 也改为返回 `SemanticColorRef`：

```swift
func demoLogColor(_ level: String) -> SemanticColorRef {
    switch level {
    case "WARN":  return .warning
    case "DEBUG": return .info
    case "ERROR": return .error
    default:      return .success
    }
}
```

把顶层 `.theme(.defaultDark)` 换成 `.theme(.defaultLight)` 应一次性切换全部调色。

---

## 11. 与 Phase 8（动画）的衔接

Phase 7.5 仅暴露 `MotionScale` 类型与默认值，不引入 `withAnimation` / `Transition` / `AnimatableModifier`。后续 Phase 8 在以下点接入即可：

- `ButtonStyleConfiguration.isPressed/isHovered` 状态切换的颜色过渡：消费 `theme.motion.fast`。
- `Panel` / `Tab` 切换的内容淡入：消费 `theme.motion.standard`。
- `ContextMenu` 弹出：消费 `theme.motion.emphasized`。

只要 Phase 7.5 的 token 命名稳定，Phase 8 不需要改 style。

---

## 12. 测试与验收

```
GuavaUI/Tests/GuavaUIComposeTests/Theme/
├── ThemeProvisionTests.swift          // .theme(_:) 覆盖最近祖先生效
├── SemanticColorResolveTests.swift    // SemanticColorRef 在缺省主题下解析
├── ButtonStyleSelectionTests.swift    // .buttonStyle(.primary) 在嵌套 .secondary 下被覆盖
├── DefaultPanelStyleTests.swift       // 默认外观快照（结构断言）
└── DemoCompilationTests.swift         // Demo 改造后仍可编译并组装节点树
```

人工验收：

```bash
cd GuavaUI && swift test
cd GuavaUI && swift run GuavaUIDemo
# 1. 启动后默认暗色主题，与 SwiftUI / VS Code Dark+ 视觉差距收敛到 token 取值层面。
# 2. 顶层 .theme(.defaultLight) 一处改动，全 demo 切到亮色，无残留硬编码颜色。
# 3. RootView 全文 grep 无 "Color(r:" 与 ".system(size:" 字面量。
# 4. Editor 接入后（M3 末），核心三面板默认外观与 demo 一致。
```

---

## 13. 实施顺序建议

| 步骤 | 内容 | 依赖 |
|------|------|------|
| 1 | 升级 `CompositionLocal` 为栈式查找；接 `ViewGraph` | Phase 6 已有 ViewGraph |
| 2 | 落 `Theme` / 各 `*Scale` / `ColorScheme` / `Typography` 类型 | 步骤 1 |
| 3 | 实现 `DefaultDarkTheme.value` | 步骤 2 |
| 4 | 实现 `ThemeEnvironment` + `.theme(_:)` modifier + `ThemeReader` | 步骤 1, 3 |
| 5 | 实现 `SemanticColorRef` / `SemanticFontRef` 与 `foregroundColor/background/font` 重载 | 步骤 4 |
| 6 | 实现 `ButtonStyle` 协议链 + 三个默认 style；改造 `Button` | 步骤 5 |
| 7 | 实现 `TextFieldStyle` / `PanelStyle` / `ListRowStyle` / `TreeRowStyle` / `DividerStyle` 与默认实现 | 步骤 5 |
| 8 | 改造 `TextField` / `Panel` / `List` / `Tree` / `SplitView` / `Image` 现有组件 | 步骤 6, 7 |
| 9 | 实现 `DefaultLightTheme.value` | 步骤 3 |
| 10 | 改造 `GuavaUIDemo/main.swift`，跑双主题切换 | 步骤 8, 9 |
| 11 | 补全测试 | 全部 |
