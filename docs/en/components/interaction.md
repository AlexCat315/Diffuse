# Interaction primitives

`TransitionView` combines opacity and offset using theme motion tokens. It retains content until exit completes, suppresses input while exiting, and cancels superseded animations. `DisclosureGroup` and the expanded JSON editor use it.

```swift
TransitionView(isVisible: expanded,
               transition: .opacity.combined(with: .offset(y: -4)), motion: .fast) {
    DetailsView()
}
```

`Modal(isPresented:)` requires a window-level `PortalHost`, normally provided by `LayerRoot`. It follows window resizing, traps Tab/Shift-Tab, blocks background shortcuts and releases background pointer capture. On closing, it restores previous focus if that control still exists. Existing Editor modals share `ModalFocusResource`.

`.contextMenu(onOpen:entries:)` opens a window-local menu on right-click. Update selection in `onOpen`; the menu then reads the current selection. Arrow keys, Enter, Escape and outside clicks operate the menu. Removing the presenting node also removes its portal. Hierarchy, scripts and asset rows use these menus.

Popover and context menus fit measured window bounds. Popovers flip above their anchor when possible; long menus scroll internally and resize with the window.

`VirtualList(data,id:rowHeight:)` mounts only fixed-height rows around the viewport, with three overscan rows by default and spacers preserving the full scroll range. `List` uses it internally, and the Editor script navigator uses it directly. Give the viewport an explicit height.
