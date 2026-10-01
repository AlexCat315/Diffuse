# Interaction primitives

`AnimatedVisibility` combines opacity, offset and size collapse, including asymmetric insertion and removal. It retains content until exit completes, suppresses input while exiting, and cancels superseded animations. `DisclosureGroup` and the expanded JSON editor use it. `TransitionView` provides a compatibility facade using theme motion tokens.

```swift
TransitionView(isVisible: expanded,
               transition: .opacity.combined(with: .offset(y: -4)), motion: .fast) {
    DetailsView()
}
```

`Modal(isPresented:)` requires a window-level `PortalHost`, normally provided by `LayerRoot`. It follows window resizing, traps Tab/Shift-Tab, blocks background shortcuts and releases background pointer capture. On closing, it restores previous focus if that control still exists. `FocusScope` uses the shared `ModalFocusResource`; existing Editor modals use the same scope. Menus use `restoresCommands: true` to keep undo and redo directed at the previously focused text field.

`.contextMenu(onOpen:entries:)` opens a window-local menu on right-click. Update selection in `onOpen`; the menu then reads the current selection. Arrow keys, Enter, Escape and outside clicks operate the menu. Removing the presenting node also removes its portal. Hierarchy, scripts and asset rows use these menus.

Popover and context menus fit measured window bounds. Popovers flip above their anchor when possible; long menus scroll internally and resize with the window.

`VirtualStack(data,id:rowHeight:)` mounts fixed-height rows around the viewport and supports `scrollToIndex`. `List`, `Tree`, the Editor script navigator and asset list use it. `VirtualList(data,id:rowHeight:)` remains available independently. Both default to three overscan rows and use spacers to preserve the full scroll range. Give the viewport an explicit height.
