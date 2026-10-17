# ZStack / Overlay

内容层叠容器。子视图按声明顺序层叠：后声明的在上层；`ZStack` 测量到最大子视图，不自动裁剪溢出内容。跨裁剪浮层仍用 Portal，不用 `ZStack`。

## Anatomy

```
┌─────────────────────────────┐
│  ┌───────────────────────┐  │
│  │   base layer          │  │
│  │      ┌──────────┐     │  │
│  │      │ overlay  │     │  │
│  │      └──────────┘     │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

- **base**：第一个子视图，通常提供背景或底层内容
- **overlay**：后续子视图，按声明顺序覆盖；最后一个在最上层
- **alignment**：所有子视图在容器内的对齐方式，默认 `.center`
- **stack**：测量到最大子视图；不会自动把子视图拉伸到容器尺寸

## API

```swift
ZStack(alignment: .topLeading) {
    Box {}.frame(width: 320, height: 180)
        .background(.surfaceVariant)
    Badge("Overlay", tone: .success).padding(14)
}
```

```swift
public struct ZStack<Content: View>: View {
    public init(alignment: Alignment = .center,
                @ViewBuilder content: () -> Content)
}

public struct ZStackLayout: Layout {
    public init(alignment: Alignment = .center)
}
```

`ZStackLayout` 也可以直接用于 `LayoutThatFits` 等自定义布局候选。

### 把内容附在某个视图上：`.overlay(alignment:content:)`

`ZStack` 解决“多个兄弟谁在上”的问题；如果你只是想把文字/角标附在**某一个**子视图上，用 `.overlay`，它和 SwiftUI 同名 API 同构：

```swift
Box {}.frame(width: 150, height: 72)
    .background(.accent)
    .cornerRadius(10)
    .overlay(alignment: .leading) {
        Text("Top-left layer")
            .font(.bodyStrong)
            .foregroundColor(.onAccent)
            .padding(horizontal: 14)
    }
    .padding(14)
```

`OverlayLayout` 以 base 的测量尺寸为准：overlay 不参与父级布局测量，只按 base 的 bounds 对齐；overlay 大于 base 时仍可溢出绘制。命中测试中 overlay 是后声明的子视图，优先接收指针。

## Sizing

- 容器尺寸 = 最大子视图尺寸；子视图不会被隐式拉伸。
- 子视图按 available proposal 测量；需要填满容器时显式 `.frame(maxWidth: .infinity, maxHeight: .infinity)`。
- 不裁剪溢出：子视图大于容器时继续绘制；需要裁剪时调用方加 `.clipped()`。
- 对齐只影响子视图在容器 bounds 内的位置，不改变测量结果。
- RTL 下 `.leading` / `.trailing` 按逻辑边解析；子视图自己的 `layoutDirection` 决定偏移方向。
- `.overlay` 的 base 决定尺寸；overlay 的尺寸不改变 base 或父级布局。

## Tokens

`ZStack` 本身不消费颜色、字体、圆角或间距。所有视觉与间距来自子视图：

| 槽位 | 来源 |
| ---- | ---- |
| 背景/边框/圆角 | 子视图的 `.background` / `.border` / `.cornerRadius` |
| 间距 | 子视图的 `.padding` / `.offset` |
| 命中区 | 子视图自身；触摸控件仍遵守 44pt |

## States

| 状态 | 行为 |
| ---- | ---- |
| 正常 | 所有子视图绘制；后声明的在上 |
| 重叠命中 | 后声明的子视图先接收指针；未命中再向下传递 |
| 条件隐藏 | `if` 分支卸载后不绘制、不接输入、不暴露辅助功能 |
| 透明度 0 | 仍参与布局与命中；不要用 `.opacity(0)` 代替隐藏 |
| 溢出 | 默认继续绘制；`.clipped()` 才裁剪绘制与命中 |

## Behavior

- **指针**：按子视图声明顺序反向命中；上层透明区域不会自动让点击穿透，除非该层本身不参与命中。
- **键盘/辅助功能**：每个子视图独立保留自己的 Tab 停靠、语义与动作；`ZStack` 不合并可访问性。
- **状态**：子视图身份按声明位置保留；重排时调用方应使用稳定 `id`。
- **与 Portal 的分工**：`ZStack` 是内容层叠，受父级裁剪与布局约束；Portal 是跨裁剪浮层，用于菜单、Tooltip、Dialog 等。
- **减少动画**：`ZStack` 自身无动画；子视图的进入/退出继续遵守各自动画契约。

## Authoring rules

- 底层内容先声明，覆盖层后声明；不要依赖 `zIndex` 解决同层顺序。
- 需要点击穿透时，把覆盖层设为不参与命中（例如条件不挂载），不要依赖透明像素。
- 需要裁剪时显式 `.clipped()`；否则溢出内容可能遮挡相邻布局。
- 需要跨裁剪、跟随锚点或模态焦点时用 Portal，不要用 `ZStack` 模拟。
- 不要把 `ZStack` 当作布局压缩容器；需要 flex/shrink 时用 `Box` / `Row` / `Column`。
- 把一个子视图的内容放到另一个子视图上时，优先用 `.overlay(alignment:)`；它按 base 的 bounds 布局，不会因为字号或 padding 漂移。没有 overlay 的等价写法是把内容作为 base 自己的 `Box`/`ZStack` 子节点；不要用并列的 `Text` + padding 去“对位”，否则测量、字号变化和裁剪会让它看起来偏移或溢出。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/ZStackTests.swift`）：

- `measuresAndAligns`：测量到最大子视图；`topLeading` / `center` 对齐位置。
- `rtlAlignment`：`.leading` 在 RTL 下映射到右侧。
- `topmostChildWinsHitTesting`：重叠按钮只有后声明者被激活。
- `cardContentStaysInsideItsBox`：卡片文字必须作为卡片 `Box` 的子节点，几何不得越出卡片边界（防止“看似右对齐”的并列 padding 写法回归）。
- `OverlayTests.alignment` / `OverlayTests.hitTesting`：`.overlay` 不改变 base 尺寸、按 base bounds 对齐、overlay 优先接收指针。

Gallery `zStack` 页提供分层卡片、角标、重叠按钮和显示/隐藏前层开关；`AdaptiveControlExamples` 提供 390/720/390-touch 三组预览。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component zStack --width 1000 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"role":"button","visible_only":true,"limit":100}'
guava-dev devtools input-ui 9229 --click-node <Front layer>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Last activated","visible_only":true}'
guava-dev devtools capture-ui 9229 /tmp/guava-zstack.jpg
```

## References

- SwiftUI `ZStack`
- Flutter `Stack` / `Positioned`
- CSS stacking context（`z-index` 仅作参考；GuavaUI 用声明顺序）
