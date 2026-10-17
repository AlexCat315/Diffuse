# Drag & Drop

`DragScope` 在一个子树内共享类型化 payload。`Draggable` 在越过 6pt 位移后开始拖动，`DropTarget` 只接受匹配类型并在指针进入时回调高亮。预览通过 Portal 绘制在裁剪之外。

```swift
DragScope {
    Row {
        Draggable(Track.camera, preview: { Chip("Camera") }) {
            Chip("Camera")
        }
        DropTarget(onDrop: { track in laneA = track }) {
            Lane("Lane A", value: laneA)
        }
        DropTarget(onDrop: { track in laneB = track }) {
            Lane("Lane B", value: laneB)
        }
    }
}
```

| 类型 | 说明 |
| --- | --- |
| `DragScope` | 持有会话；必须包住 source 与 target |
| `Draggable(payload, preview:content:)` | 拖动源；payload 为任意 `Hashable` |
| `DropTarget(onDrop:onTargeted:content:)` | 只接受 `Payload` 类型；hover 进入/离开调用 `onTargeted` |

## 行为

- 按下先只记录起点，不消费事件；嵌套按钮的普通点击仍然有效。位移 ≥6pt 后夺取指针捕获并开始拖动。
- 拖动时 Portal 预览跟随指针 +12pt，不参与命中；释放时命中最深的匹配 target（节点包含指针且可交互），调用一次 `onDrop`。
- 释放到所有 target 之外、或 payload 类型不匹配时不调用 drop；会话清空、预览卸载。目标离开时 `onTargeted(false)`。
- 目标按当前绝对 frame 匹配，不使用 hover 节点；同一会话内多个 target 取层级更深者。
- 无自动滚动、无键盘等价路径、无列表重排集成；集合重排继续使用 [ReorderableList](list.md#reorderablelist)。不要把 `Draggable` 直接嵌入纵向 `ScrollView` 的滚动区域，除非确实希望拖动优先于滚动。

## 验证

- `DragAndDropTests.drop`：Int payload 落到匹配 target，回调一次；String target 不接收。
- `DragAndDropTests.cancel`：释放到外部不 drop。
- `DragAndDropTests.preview`：拖动中 Portal 有 1 个预览，释放后清空；指针捕获释放。
- Gallery `dragAndDrop` 页：三个 chip、两个 lane、结果文本 `drop-result`；DevTools 720×820 通过 `input-ui` 从 Camera 拖到 Lane A 后查询到 `A: Camera · B: empty`，`capture-ui` 确认落位。

## File map

- 主体：[DragAndDrop.swift](../../GuavaUI/Sources/GuavaUICompose/Primitives/Interaction/DragAndDrop.swift)
- 测试：[DragAndDropTests.swift](../../GuavaUI/Tests/GuavaUIComposeTests/DragAndDropTests.swift)
