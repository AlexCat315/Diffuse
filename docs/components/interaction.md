# 通用交互组件

## 组合过渡

`TransitionView` 使用同一动画进度组合透明度和位移。退出完成后再卸载内容；退出中的内容不接收输入。快速切换会取消旧动画。动画时长从当前主题的 motion token 读取。

```swift
TransitionView(isVisible: expanded,
               transition: .opacity.combined(with: .offset(y: -4)), motion: .fast) {
    DetailsView()
}
```

已应用到 `DisclosureGroup` 和 JSON 模态编辑器的入场。

## 模态与焦点

```swift
LayerRoot {
    Modal(isPresented: $shown) { EditorForm() }
}
```

`Modal` 居中显示并随窗口大小更新。模态存在时，Tab / Shift-Tab 在内部循环，背景快捷键和拖拽不继续执行。关闭时恢复打开前的焦点；原控件已卸载时不恢复到失效节点。已有编辑器模态也通过 `ModalFocusResource` 使用同一焦点范围机制。

## 右键菜单

```swift
EntityRow(entity)
    .contextMenu(onOpen: { selectTarget(entity) }, entries: {
        [.item(MenuItem(id: "rename", title: "Rename", action: rename))]
    })
```

菜单通过窗口自己的 portal 显示，右键不会启动普通行点击或拖拽。支持方向键、Enter、Esc 和点击外部关闭；父节点卸载时自动清理。`onOpen` 先更新目标选择，`entries` 随后读取当前选区，保留对已选中目标的多选操作。

层级条目使用重命名、复制、删除、显示/隐藏、锁定、移动等已有操作；脚本和资源列表也接入右键入口。普通 Popover 与右键菜单均按窗口实测边界限位，必要时向上显示；长菜单内部滚动并随窗口缩放更新高度。
