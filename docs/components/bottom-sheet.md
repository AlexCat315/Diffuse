# BottomSheet

手机优先的底部抽屉。复用 `Modal` 的 backdrop、焦点约束、Escape 和焦点还原；本组件只负责拖拽柄、detent 高度和 compact/expanded 几何。

## Anatomy

```
┌──────────────────────────────────────┐
│              ────                    │  ← handle, 44pt hit / 4pt visual
│  Quick actions                       │
│  Drag the handle up for more space.  │
│                                      │
│  [Notifications        ●]            │
│                          [Close]     │
└──────────────────────────────────────┘
```

- **handle**：全宽 44pt 命中区，中央 36×4 视觉条
- **content**：调用方内容；高度由 detent 决定
- **detent**：从最小到最大的高度档位；向上拖展开，向下拖收缩或关闭
- **backdrop / focus**：由 `Modal` 提供；Escape、背景点击遵循 `ModalDismissal`

## API

```swift
@State private var open = false

BottomSheet(isPresented: $open, configure: {
    $0.detents = [280, 480]
    $0.initialDetent = 0
    $0.dragDismissThreshold = 70
}) {
    VStack {
        Text("Quick actions")
        Button("Close") { open = false }
    }
}
```

| 参数 | 默认值 | 说明 |
| ---- | ---- | ---- |
| `detents` | `[320, 560]` | 高度档位，按从小到大排列 |
| `initialDetent` | `0` | 初始档位索引，自动夹紧 |
| `showsHandle` | `true` | 是否显示拖拽柄 |
| `allowsDragToDismiss` | `true` | 第一档向下拖是否允许关闭 |
| `dragDismissThreshold` | `80` | 位移阈值（pt） |
| `dragDismissVelocity` | `900` | 速度阈值（pt/s） |
| `dismissal` | `ModalDismissal()` | Escape / backdrop 关闭策略 |
| `dialogWidth` | `560` | expanded 表面退化为居中面板时的宽度 |
| `dialogInset` | `16` | expanded 面板与窗口的 inset |

## Sizing

- compact/medium（width < 1000）：底部贴边、全宽；高度为当前 detent。
- expanded（≥1000）：退化为居中面板，宽度 `min(dialogWidth, 窗口 − 2×inset)`；高度仍为当前 detent。
- handle 命中区 44pt；视觉条 36×4。
- content 由调用方排版；需要滚动时在 content 内使用 `ScrollView`。
- 面板高度受 `ModalGeometry` 夹紧到窗口；detent 超过窗口时按窗口上限显示。

## Tokens

| 槽位 | 来源 |
| ---- | ---- |
| 面板背景/边框/圆角 | `Modal` 的 `surface` / `border` / `geometry.cornerRadius=12` |
| handle | `theme.colors.onSurfaceMuted` |
| backdrop | `Modal` 默认 standard / selection |
| 焦点环/按钮 | 内容自身控件 |

## States

| 状态 | 行为 |
| ---- | ---- |
| 关闭 | 不挂载 content；`Modal` 保留退出动画 |
| 打开 | 焦点进入；Escape / backdrop 按 `dismissal` 关闭 |
| 拖动中 | content 随 handle 位移；不把拖动传给内容 |
| 向上释放 | 进入下一档 detent；已是最大档则回到原位 |
| 向下释放 | 非第一档时退一档；第一档且超过阈值/速度时关闭 |
| 未超过阈值 | 回到当前 detent |
| disabled / reduced motion | 不注册惯性；释放立即回位（无 spring 尾段） |

## Behavior

- **指针**：handle 左键拖拽；按下时捕获指针，释放后释放捕获。
- **键盘**：Escape 关闭；内容控件保持自己的键盘可达性。handle 目前是发现用的语义节点，键盘档位切换待补。
- **辅助功能**：handle label `"Resize sheet"`；content 的 role= dialog 由 `Modal` 提供，标题由内容声明。
- **焦点**：沿用 `Modal` 的 FocusScope；关闭后焦点还原到打开前的控件。
- **自适应**：`WidthClassReader` 按实际表面宽度选择底部或居中；不读平台 API。
- **安全区**：底部/顶部 inset 由宿主安全区壳层负责；组件不自行推断 home indicator。
- **限制**：当前释放直接回位，没有 spring 惯性/阻尼；这是 reduced-motion 安全的实现，后续可把 `SpringDragSession` 接入。

## Authoring rules

- 需要简单边缘面板用 `Sheet`；需要 detent/拖拽/手机底部语义用 `BottomSheet`。
- detents 从小到大、数量控制在 2–3 个；第一档要能容纳最关键的操作。
- content 自己负责滚动和底部安全区；不要把长列表直接塞进固定高度而不给 `ScrollView`。
- 不要用 `BottomSheet` 承载阻塞式确认；确认用 `AlertDialog`。
- 宽屏退化是产品选择；需要宽屏仍贴底时用 `Sheet(edge: .bottom)`。

## Verification

单元测试（`GuavaUI/Tests/GuavaUIComposeTests/BottomSheetTests.swift`）：

- `dragDismisses`：第一档向下拖超过阈值关闭。
- `dragExpands`：向上拖进入第二档，content 高度 400。
- `expandedSurface`：expanded 表面退化为宽 560 的居中面板。

Gallery `bottomSheet` 页提供打开、拖拽、detent 与关闭；`Sheet` 页保留简单四边 Sheet 对照。DevTools 实测 390×800 时 dialog 为 390×280、y=520（底部贴边），1280×840 时为 560×280、x=360/y=280（居中）。

DevTools 闭环：

```sh
GUAVA_DEVTOOLS=1 GuavaUI/Examples/.build/out/Products/Debug/GuavaUIDemo \
  --component bottomSheet --width 390 --height 760

guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Open bottom sheet","role":"button","visible_only":true}'
guava-dev devtools input-ui 9229 --click-node <open>
guava-dev devtools query-ui 9229 query_ui_nodes \
  '{"text":"Resize sheet","visible_only":true}'   # frame y=480, h=44
guava-dev devtools input-ui 9229 --input \
  '[{"kind":"pointerDown","x":195,"y":502},{"kind":"pointerMove","x":195,"y":622},{"kind":"pointerUp","x":195,"y":622}]'
guava-dev devtools capture-ui 9229 /tmp/guava-bottomsheet.jpg
```

宽屏（1000×760）验证居中退化与 detent：handle y 从 240（280 高）拖到 140（480 高）。

## References

- SwiftUI `.sheet` + `.presentationDetents`
- Flutter `showModalBottomSheet` / `DraggableScrollableSheet`
